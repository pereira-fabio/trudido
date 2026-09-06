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

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'sync_types.dart';

/// Records which local records have changed since the last successful push.
///
/// This is an outbox rather than a dirty-flag scan for two reasons: it avoids
/// walking every box to find a handful of changes, and it is the only way to
/// learn about a *hard* delete — `permanentlyDelete*` and the bin purge remove
/// the row entirely, leaving nothing behind to mark.
///
/// Entries are keyed `collection:id`, so a record edited twenty times between
/// syncs occupies one slot and is sent once.
class SyncQueue {
  static const String boxName = 'sync_queue';
  static Box<String>? _box;

  /// Gates recording. Left false until sync is configured so that a user who
  /// never self-hosts pays nothing — no box, no writes, no growth.
  static bool enabled = false;

  /// True while changes pulled from the server are being written locally.
  ///
  /// This guards two things at once, and both matter. It keeps the outbox from
  /// re-queueing a record we just received, which would push it straight back
  /// and, with two devices syncing, never settle. And it tells StorageService
  /// to leave `updatedAt` alone, so the server's timestamp survives the write
  /// instead of being stamped to now -- which would make every pulled record
  /// look like the newest edit in existence.
  static bool suppressed = false;

  /// Runs [body] with remote-apply semantics, restoring the previous state
  /// even if it throws. Nested calls are safe.
  static Future<T> applyingRemote<T>(Future<T> Function() body) async {
    final previous = suppressed;
    suppressed = true;
    try {
      return await body();
    } finally {
      suppressed = previous;
    }
  }

  static bool get isOpen => _box != null;

  /// Opens the outbox. Safe to call more than once.
  static Future<void> init() async {
    if (_box != null) return;
    try {
      _box = await Hive.openBox<String>(boxName);
    } catch (e) {
      debugPrint('[SyncQueue] Failed to open outbox: $e');
      rethrow;
    }
  }

  static String _key(String collection, String id) => '$collection:$id';

  /// Notes a local change. Never throws: a sync bookkeeping failure must not
  /// take down the write that triggered it.
  ///
  /// A [SyncOp.delete] always wins over a pending [SyncOp.upsert] for the same
  /// record — if it was edited and then destroyed before we synced, the only
  /// thing the server needs is the tombstone.
  static void record(
    String collection,
    String id, {
    SyncOp op = SyncOp.upsert,
    DateTime? updatedAt,
  }) {
    if (!enabled || suppressed) return;
    final box = _box;
    if (box == null) return;
    try {
      final key = _key(collection, id);
      if (op == SyncOp.upsert) {
        final existing = box.get(key);
        if (existing != null &&
            SyncOpWire.parse(
                  (jsonDecode(existing) as Map)['op'] as String?,
                ) ==
                SyncOp.delete) {
          return;
        }
      }
      box.put(
        key,
        jsonEncode({
          'collection': collection,
          'id': id,
          'op': op.wire,
          'updated_at': (updatedAt ?? DateTime.now())
              .toUtc()
              .toIso8601String(),
        }),
      );
    } catch (e) {
      debugPrint('[SyncQueue] Could not record $collection/$id: $e');
    }
  }

  /// Convenience for the common case of many ids in one collection.
  static void recordAll(
    String collection,
    Iterable<String> ids, {
    SyncOp op = SyncOp.upsert,
  }) {
    for (final id in ids) {
      record(collection, id, op: op);
    }
  }

  /// Everything waiting to be pushed.
  static List<SyncQueueEntry> pending() {
    final box = _box;
    if (box == null) return const [];
    final out = <SyncQueueEntry>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        out.add(SyncQueueEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (e) {
        debugPrint('[SyncQueue] Dropping unreadable entry $key: $e');
        box.delete(key);
      }
    }
    return out;
  }

  /// The queued change for one record, if any.
  ///
  /// Pull consults this before writing an incoming record: a local edit that
  /// has not been sent yet is not visible to the server, so the server's copy
  /// is not automatically the newer one and must not simply overwrite it.
  static SyncQueueEntry? entryFor(String collection, String id) {
    final raw = _box?.get(_key(collection, id));
    if (raw == null) return null;
    try {
      return SyncQueueEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Drops one queued change, for when an incoming record supersedes it.
  static Future<void> remove(String collection, String id) async =>
      _box?.delete(_key(collection, id));

  static int get length => _box?.length ?? 0;

  /// Clears entries the server accepted. Entries recorded *during* the push
  /// are keyed identically, so this can drop a change newer than the one that
  /// was sent; callers pass the entries they actually pushed and accept that
  /// a same-record re-edit mid-flight is re-sent on the next pass instead.
  static Future<void> clear(Iterable<SyncQueueEntry> entries) async {
    final box = _box;
    if (box == null) return;
    await box.deleteAll(entries.map((e) => _key(e.collection, e.id)));
  }

  static Future<void> clearAll() async => _box?.clear();

  /// Enqueues a whole collection, for the first sync after sync is switched on
  /// (or after a "resync everything" from settings). Without this, records
  /// that predate sync would never be offered to the server.
  ///
  /// Takes each record's own timestamp rather than stamping `now`: a baseline
  /// push carrying "everything changed this second" would beat genuinely newer
  /// edits already on the server and silently roll another device back.
  static Future<void> markAllDirty(
    String collection,
    Map<String, DateTime> idsWithTimestamps,
  ) async {
    final box = _box;
    if (box == null) return;
    await box.putAll({
      for (final entry in idsWithTimestamps.entries)
        _key(collection, entry.key): jsonEncode({
          'collection': collection,
          'id': entry.key,
          'op': SyncOp.upsert.wire,
          'updated_at': entry.value.toUtc().toIso8601String(),
        }),
    });
  }

  @visibleForTesting
  static void setTestBox(Box<String> box) => _box = box;
}

class SyncQueueEntry {
  final String collection;
  final String id;
  final SyncOp op;
  final DateTime updatedAt;

  const SyncQueueEntry({
    required this.collection,
    required this.id,
    required this.op,
    required this.updatedAt,
  });

  static SyncQueueEntry fromJson(Map<String, dynamic> json) => SyncQueueEntry(
    collection: json['collection'] as String,
    id: json['id'] as String,
    op: SyncOpWire.parse(json['op'] as String?),
    updatedAt: DateTime.parse(json['updated_at'] as String).toLocal(),
  );
}
