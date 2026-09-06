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

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../utils/media_ref.dart';
import '../storage_service.dart';
import 'sync_api_client.dart';

/// Result of one attachment pass, for the status line.
class MediaSyncResult {
  final int uploaded;
  final int downloaded;
  final int failed;

  const MediaSyncResult({
    this.uploaded = 0,
    this.downloaded = 0,
    this.failed = 0,
  });

  bool get didSomething => uploaded > 0 || downloaded > 0;
}

/// Moves note attachments between this device and the server.
///
/// Reconciliation rather than a change log: it works out what every note
/// currently refers to, compares that against what is here and what the server
/// holds, and moves the difference. That costs one manifest request and a scan
/// of note content, and in exchange it is self-healing -- an upload that failed
/// last time, a file restored from a backup, a note that arrived before its
/// image, all sort themselves out on the next pass without anything having had
/// to record that they were outstanding.
class MediaSync {
  const MediaSync();

  /// Filenames referred to by any note, including notes in the bin -- those
  /// can still be restored, and an attachment deleted from under one would
  /// come back broken.
  Future<Set<String>> _referencedFileNames() async {
    await StorageService.waitNotesReady();
    final names = <String>{};
    for (final note in [
      ...StorageService.getAllNotes(),
      ...StorageService.getDeletedNotes(),
    ]) {
      names.addAll(MediaRef.referencedIn(note.content));
    }
    return names;
  }

  Future<String?> _sha256Of(File file) async {
    try {
      // Streamed rather than read whole: a video note can be hundreds of
      // megabytes, and this runs on the same isolate as the UI.
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString();
    } catch (e) {
      debugPrint('[MediaSync] Could not hash ${file.path}: $e');
      return null;
    }
  }

  /// One reconciliation pass.
  Future<MediaSyncResult> run(SyncApiClient client) async {
    if (!MediaRef.isConfigured) {
      debugPrint('[MediaSync] Media directory unknown; skipping.');
      return const MediaSyncResult();
    }

    final referenced = await _referencedFileNames();
    if (referenced.isEmpty) return const MediaSyncResult();

    final Set<String> serverHashes;
    final Map<String, String> serverByFileName;
    try {
      final manifest = await client.blobManifestDetailed();
      serverHashes = manifest.keys.toSet();
      // Filenames carry a millisecond timestamp, so a collision needs two
      // devices creating the same kind of file in the same millisecond. If it
      // happens the first wins, and the other note shows a broken embed rather
      // than the wrong picture.
      serverByFileName = <String, String>{};
      for (final entry in manifest.entries) {
        serverByFileName.putIfAbsent(entry.value, () => entry.key);
      }
    } catch (e) {
      debugPrint('[MediaSync] Could not read manifest: $e');
      return const MediaSyncResult(failed: 1);
    }

    var uploaded = 0, downloaded = 0, failed = 0;

    for (final fileName in referenced) {
      final file = File(MediaRef.resolve(fileName));

      if (file.existsSync()) {
        final hash = await _sha256Of(file);
        if (hash == null) {
          failed++;
          continue;
        }
        if (serverHashes.contains(hash)) continue;
        try {
          await client.uploadBlob(hash, fileName, await file.readAsBytes());
          uploaded++;
        } catch (e) {
          debugPrint('[MediaSync] Upload of $fileName failed: $e');
          failed++;
        }
        continue;
      }

      // Referenced but not here: another device has it, or this is a false
      // positive from the content scan, in which case the manifest simply
      // will not know the name and it is skipped.
      final hash = serverByFileName[fileName];
      if (hash == null) continue;
      try {
        final bytes = await client.downloadBlob(hash);
        await file.parent.create(recursive: true);
        // Written beside the target and renamed, so an interrupted download
        // cannot leave a truncated file that later looks complete.
        final temporary = File('${file.path}.part');
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
        downloaded++;
      } catch (e) {
        debugPrint('[MediaSync] Download of $fileName failed: $e');
        failed++;
      }
    }

    if (uploaded > 0 || downloaded > 0 || failed > 0) {
      debugPrint(
        '[MediaSync] $uploaded up, $downloaded down, $failed failed',
      );
    }
    return MediaSyncResult(
      uploaded: uploaded,
      downloaded: downloaded,
      failed: failed,
    );
  }
}
