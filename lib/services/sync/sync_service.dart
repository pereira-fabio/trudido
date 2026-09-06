// Trudido - A privacy-focused todo and notes app
// Copyright (C) 2026 Dominik Müller
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sync_api_client.dart';
import 'sync_config.dart';
import 'sync_queue.dart';
import 'sync_repository_bridge.dart';
import 'sync_types.dart';

enum SyncPhase { idle, connecting, pulling, pushing, done, failed }

@immutable
class SyncStatus {
  final SyncPhase phase;
  final int pulled;
  final int pushed;
  final int conflicts;
  final String? error;
  final DateTime? lastSyncAt;
  final int pending;

  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.pulled = 0,
    this.pushed = 0,
    this.conflicts = 0,
    this.error,
    this.lastSyncAt,
    this.pending = 0,
  });

  bool get isRunning =>
      phase == SyncPhase.connecting ||
      phase == SyncPhase.pulling ||
      phase == SyncPhase.pushing;

  SyncStatus copyWith({
    SyncPhase? phase,
    int? pulled,
    int? pushed,
    int? conflicts,
    String? error,
    bool clearError = false,
    DateTime? lastSyncAt,
    int? pending,
  }) => SyncStatus(
    phase: phase ?? this.phase,
    pulled: pulled ?? this.pulled,
    pushed: pushed ?? this.pushed,
    conflicts: conflicts ?? this.conflicts,
    error: clearError ? null : (error ?? this.error),
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    pending: pending ?? this.pending,
  );
}

/// Drives one sync pass: pull what changed, then offer what we changed.
///
/// Pull runs first on purpose. Pushing first would hand the server our version
/// of a record we have not yet seen the newer copy of, and though the server
/// would reject it, we would then have to reconcile a rejection we could have
/// avoided by simply reading first.
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  final SyncRepositoryBridge _bridge = SyncRepositoryBridge();

  final _statusController = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get statusStream => _statusController.stream;

  SyncStatus _status = const SyncStatus();
  SyncStatus get status => _status;

  /// Guards against a manual tap racing the on-resume trigger. A second caller
  /// joins the run in flight rather than starting a competing one.
  Future<SyncResult>? _inFlight;

  Timer? _autoTimer;

  /// How often the periodic pass runs when it is started. Long, because the
  /// resume trigger covers the case that actually matters on a phone; this is
  /// for the browser, where a tab can sit open for hours and never resume.
  static const Duration periodicInterval = Duration(minutes: 15);

  void _emit(SyncStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  /// Starts the periodic pass. The phone relies on [syncOnResume] instead, so
  /// this is only worth starting where there is no resume event to hook.
  void startPeriodic({Duration? interval}) {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(interval ?? periodicInterval, (_) {
      if (SyncConfig.isConfigured && SyncConfig.autoSync) sync();
    });
  }

  void stopPeriodic() {
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  /// Prepares sync without contacting anything. Safe on every app start.
  Future<void> init() async {
    await SyncConfig.init();
    if (!SyncConfig.isConfigured) return;
    await SyncQueue.init();
    SyncQueue.enabled = true;
    _emit(
      _status.copyWith(
        lastSyncAt: SyncConfig.lastSyncAt,
        pending: SyncQueue.length,
        error: SyncConfig.lastError,
      ),
    );
  }

  SyncApiClient _client() => SyncApiClient(
    baseUrl: SyncConfig.serverUrl,
    token: SyncConfig.token,
  );

  /// Checks the URL and token. Used by "Test connection" before saving.
  Future<bool> testConnection({String? url, String? token}) async {
    final client = SyncApiClient(
      baseUrl: (url ?? SyncConfig.serverUrl).replaceAll(RegExp(r'/+$'), ''),
      token: token ?? SyncConfig.token,
    );
    try {
      return await client.checkAuth();
    } finally {
      client.close();
    }
  }

  /// Switches sync on and seeds the outbox with everything already stored.
  ///
  /// Without the baseline pass, records that predate sync would sit here
  /// forever: nothing ever marked them changed, so nothing would ever send
  /// them. Each is queued with its own timestamp, not now, so this cannot
  /// out-rank genuinely newer edits already on the server.
  Future<void> enable({required String serverUrl, required String token}) async {
    await SyncConfig.init();
    await SyncConfig.setServerUrl(serverUrl);
    await SyncConfig.setToken(token);
    await SyncConfig.setEnabled(true);
    await SyncQueue.init();
    SyncQueue.enabled = true;

    for (final collection in SyncCollection.all) {
      if (collection == SyncCollection.settings) continue;
      try {
        final baseline = await _bridge.baselineFor(collection);
        if (baseline.isNotEmpty) {
          await SyncQueue.markAllDirty(collection, baseline);
        }
      } catch (e) {
        debugPrint('[Sync] Could not seed $collection: $e');
      }
    }
    _emit(_status.copyWith(pending: SyncQueue.length));
  }

  /// Turns sync off and stops recording. Local data is untouched, and the
  /// server keeps its copy -- this is not a delete.
  Future<void> disable() async {
    await SyncConfig.setEnabled(false);
    SyncQueue.enabled = false;
    _autoTimer?.cancel();
    _autoTimer = null;
    _emit(const SyncStatus());
  }

  /// Re-reads the whole server history and re-offers everything local. The
  /// repair for a cursor that has drifted, or a server restored from backup.
  Future<SyncResult> resync() async {
    await SyncConfig.resetCursor();
    await enable(serverUrl: SyncConfig.serverUrl, token: SyncConfig.token);
    return sync();
  }

  Future<SyncResult> sync() {
    final running = _inFlight;
    if (running != null) return running;
    final future = _run();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<SyncResult> _run() async {
    if (!SyncConfig.isConfigured) {
      return const SyncResult(ok: false, error: 'Sync is not configured.');
    }

    final client = _client();
    var pulled = 0, pushed = 0, conflicts = 0;

    try {
      _emit(_status.copyWith(phase: SyncPhase.connecting, clearError: true));

      // ---- pull ----
      _emit(_status.copyWith(phase: SyncPhase.pulling));
      final firstPull = await _pullLoop(client, (n) {
        _emit(_status.copyWith(pulled: pulled + n));
      });
      pulled += firstPull.applied;
      conflicts += firstPull.superseded;

      // ---- push ----
      _emit(_status.copyWith(phase: SyncPhase.pushing));
      final entries = SyncQueue.pending();
      final pushedKeys = <String>{};
      if (entries.isNotEmpty) {
        const batchSize = 200;
        for (var i = 0; i < entries.length; i += batchSize) {
          final batch = entries.skip(i).take(batchSize).toList();
          final records = <SyncRecord>[];

          for (final entry in batch) {
            if (entry.op == SyncOp.delete) {
              records.add(
                SyncRecord(
                  collection: entry.collection,
                  id: entry.id,
                  updatedAt: entry.updatedAt,
                  deleted: true,
                ),
              );
              continue;
            }
            final record = await _bridge.readOne(entry.collection, entry.id);
            // Queued as an edit but gone by the time we drained: it was
            // deleted after being queued, so send the tombstone instead.
            records.add(
              record ??
                  SyncRecord(
                    collection: entry.collection,
                    id: entry.id,
                    updatedAt: entry.updatedAt,
                    deleted: true,
                  ),
            );
          }

          pushedKeys.addAll(records.map((r) => '${r.collection}:${r.id}'));
          final result = await client.push(SyncConfig.deviceId, records);
          pushed += result.applied;
          conflicts += result.rejections.length;

          // A rejection means the server holds something newer. Adopt it now
          // rather than waiting for the next pull, so the two agree before
          // the user touches the record again.
          for (final rejection in result.rejections) {
            final serverRecord = rejection.serverRecord;
            if (serverRecord != null) {
              await _bridge.applyRemote(serverRecord);
            }
          }

          await SyncQueue.clear(batch);
          _emit(_status.copyWith(pushed: pushed, conflicts: conflicts));
        }

        // Our own push advanced the server's history past our cursor. Draining
        // it here costs one request and leaves the cursor at the true head;
        // skipping it would mean the next sync re-reads everything we just
        // sent. Re-applying our own records is a no-op -- same content, same
        // timestamp -- and this pass also collects anything another device
        // pushed while we were sending.
        final drain = await _pullLoop(client, null, echoes: pushedKeys);
        pulled += drain.applied;
        conflicts += drain.superseded;
      }

      final now = DateTime.now();
      await SyncConfig.setLastSyncAt(now);
      await SyncConfig.setLastError(null);
      _emit(
        _status.copyWith(
          phase: SyncPhase.done,
          pulled: pulled,
          pushed: pushed,
          conflicts: conflicts,
          lastSyncAt: now,
          pending: SyncQueue.length,
          clearError: true,
        ),
      );
      return SyncResult(
        ok: true,
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
      );
    } on SyncApiException catch (e) {
      await SyncConfig.setLastError(e.message);
      _emit(
        _status.copyWith(
          phase: SyncPhase.failed,
          error: e.message,
          pending: SyncQueue.length,
        ),
      );
      return SyncResult(ok: false, error: e.message);
    } catch (e, st) {
      debugPrint('[Sync] Unexpected failure: $e\n$st');
      final message = 'Sync failed: $e';
      await SyncConfig.setLastError(message);
      _emit(
        _status.copyWith(
          phase: SyncPhase.failed,
          error: message,
          pending: SyncQueue.length,
        ),
      );
      return SyncResult(ok: false, error: message);
    } finally {
      client.close();
    }
  }

  /// Writes one pulled record, unless a newer local edit is still waiting.
  ///
  /// The server's copy is not automatically the newer one. An edit made on
  /// this device while offline has never been offered to the server, so a
  /// record arriving from it can easily be older than what is sitting in the
  /// outbox. Applying it blindly would destroy that edit before the push that
  /// was about to carry it -- silently, and without registering as a conflict.
  Future<({bool applied, bool superseded})> _applyPulled(SyncRecord record) async {
    final pending = SyncQueue.entryFor(record.collection, record.id);

    if (pending != null && pending.updatedAt.isAfter(record.updatedAt)) {
      // Ours is newer. Leave local storage alone; the push carries it, and
      // the server resolves it there under the same rule.
      return (applied: false, superseded: false);
    }

    final applied = await _bridge.applyRemote(record);

    if (applied && pending != null) {
      // Ours lost. Drop the queued change rather than pushing back a copy of
      // what we just received. For notes the superseded text has already been
      // written into note history by the bridge, so nothing is unrecoverable.
      await SyncQueue.remove(record.collection, record.id);
      // Counted as a conflict even though the server never saw it: an edit
      // made on this device was overruled, and that is worth telling the user
      // whichever side happened to detect it.
      return (applied: true, superseded: true);
    }
    return (applied: applied, superseded: false);
  }

  /// Reads pages until the server has nothing newer, applying as it goes.
  ///
  /// The cursor is saved only after a page has been applied, so an
  /// interruption re-reads that page rather than stepping over it. Re-applying
  /// a record is harmless; missing one is not.
  /// [echoes] names records this device just pushed. They come back on the
  /// drain pass and are applied harmlessly, but counting them as "received"
  /// would tell the user they got changes from elsewhere when they did not.
  Future<({int applied, int superseded})> _pullLoop(
    SyncApiClient client,
    void Function(int)? onProgress, {
    Set<String> echoes = const {},
  }) async {
    var applied = 0;
    var superseded = 0;
    var guard = 0;
    while (true) {
      // A server that always reports has_more would otherwise spin forever.
      if (++guard > 1000) {
        throw const SyncApiException('Pull did not terminate; aborting.');
      }
      final page = await client.pull(SyncConfig.cursor);
      for (final record in page.records) {
        final outcome = await _applyPulled(record);
        if (outcome.applied &&
            !echoes.contains('${record.collection}:${record.id}')) {
          applied++;
        }
        if (outcome.superseded) superseded++;
      }
      await SyncConfig.setCursor(page.cursor);
      onProgress?.call(applied);
      if (!page.hasMore) return (applied: applied, superseded: superseded);
    }
  }

  /// Called when the app returns to the foreground. Quiet by design: a failure
  /// here is recorded but never interrupts the user, who did not ask for it.
  Future<void> syncOnResume() async {
    if (!SyncConfig.isConfigured || !SyncConfig.autoSync) return;
    // A sync a few seconds ago will not have missed anything worth a round
    // trip; app switching should not mean a request per switch.
    final last = SyncConfig.lastSyncAt;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 30)) {
      return;
    }
    await sync();
  }

  void dispose() {
    _autoTimer?.cancel();
    _statusController.close();
  }
}

class SyncResult {
  final bool ok;
  final int pulled;
  final int pushed;
  final int conflicts;
  final String? error;

  const SyncResult({
    required this.ok,
    this.pulled = 0,
    this.pushed = 0,
    this.conflicts = 0,
    this.error,
  });
}
