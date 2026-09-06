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

import '../../models/event.dart';
import '../../models/folder.dart';
import '../../models/folder_template.dart';
import '../../models/note.dart';
import '../../models/note_folder.dart';
import '../../models/note_history.dart';
import '../../models/todo.dart';
import '../storage_service.dart';
import 'sync_queue.dart';
import 'sync_types.dart';

/// Translates between the wire format and local storage.
///
/// Every write here goes through the ordinary StorageService and repository
/// paths rather than touching Hive directly, so vault encryption, bin rules
/// and folder bookkeeping all still apply. What changes is the context: writes
/// run inside [SyncQueue.applyingRemote], which stops the record being queued
/// straight back to the server and preserves the timestamp it arrived with.
class SyncRepositoryBridge {
  /// Reads one collection as it should be sent to the server.
  Future<List<SyncRecord>> readAll(String collection) async {
    switch (collection) {
      case SyncCollection.todos:
        await StorageService.waitTodosReady();
        final todos = await StorageService.getAllTodosAsync();
        final deleted = await StorageService.getDeletedTodos();
        return [
          for (final t in [...todos, ...deleted])
            SyncRecord(
              collection: collection,
              id: t.id,
              payload: t.toJson(),
              updatedAt: t.effectiveUpdatedAt,
            ),
        ];

      case SyncCollection.notes:
        await StorageService.waitNotesReady();
        return [
          for (final n in [
            ...StorageService.getAllNotes(),
            ...StorageService.getDeletedNotes(),
          ])
            SyncRecord(
              collection: collection,
              id: n.id,
              payload: n.toJson(),
              updatedAt: n.updatedAt,
            ),
        ];

      case SyncCollection.events:
        await StorageService.waitEventsReady();
        final events = await StorageService.getAllEventsAsync();
        final deleted = await StorageService.getDeletedEvents();
        return [
          for (final e in [...events, ...deleted])
            SyncRecord(
              collection: collection,
              id: e.id,
              payload: e.toJson(),
              updatedAt: e.effectiveUpdatedAt,
            ),
        ];

      case SyncCollection.noteFolders:
        await StorageService.waitNoteFoldersReady();
        return [
          for (final f in StorageService.getAllNoteFolders())
            SyncRecord(
              collection: collection,
              id: f.id,
              payload: f.toJson(),
              updatedAt: f.updatedAt,
            ),
        ];

      case SyncCollection.folders:
        final repo = StorageService.folderRepository;
        if (repo == null) return const [];
        return [
          for (final f in await repo.getAllFolders())
            SyncRecord(
              collection: collection,
              id: f.id,
              payload: f.toJson(),
              updatedAt: f.updatedAt,
            ),
        ];

      case SyncCollection.templates:
        final repo = StorageService.templateRepository;
        if (repo == null) return const [];
        return [
          for (final t in await repo.getAllTemplates())
            SyncRecord(
              collection: collection,
              id: t.id,
              payload: t.toJson(),
              updatedAt: t.updatedAt,
            ),
        ];

      case SyncCollection.themes:
        return [
          for (final entry in StorageService.getAllCustomThemesRaw().entries)
            SyncRecord(
              collection: collection,
              id: entry.key,
              payload: {'json': entry.value},
              // Themes carry no timestamp of their own, so they lose to any
              // dated record. They change rarely and only deliberately.
              updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
            ),
        ];

      default:
        return const [];
    }
  }

  /// Reads a single record, for draining the outbox without loading a whole
  /// collection. Returns null when the record is gone, which the caller turns
  /// into a tombstone.
  Future<SyncRecord?> readOne(String collection, String id) async {
    switch (collection) {
      case SyncCollection.todos:
        await StorageService.waitTodosReady();
        final todo = await StorageService.getTodoAsync(id);
        return todo == null
            ? null
            : SyncRecord(
                collection: collection,
                id: id,
                payload: todo.toJson(),
                updatedAt: todo.effectiveUpdatedAt,
              );

      case SyncCollection.notes:
        await StorageService.waitNotesReady();
        final note = StorageService.getNote(id);
        return note == null
            ? null
            : SyncRecord(
                collection: collection,
                id: id,
                payload: note.toJson(),
                updatedAt: note.updatedAt,
              );

      case SyncCollection.events:
        await StorageService.waitEventsReady();
        final event = await StorageService.getEventAsync(id);
        return event == null
            ? null
            : SyncRecord(
                collection: collection,
                id: id,
                payload: event.toJson(),
                updatedAt: event.effectiveUpdatedAt,
              );

      case SyncCollection.noteFolders:
        await StorageService.waitNoteFoldersReady();
        final folder = StorageService.getNoteFolder(id);
        return folder == null
            ? null
            : SyncRecord(
                collection: collection,
                id: id,
                payload: folder.toJson(),
                updatedAt: folder.updatedAt,
              );

      case SyncCollection.folders:
        final folder = await StorageService.folderRepository?.getFolderById(id);
        return folder == null
            ? null
            : SyncRecord(
                collection: collection,
                id: id,
                payload: folder.toJson(),
                updatedAt: folder.updatedAt,
              );

      case SyncCollection.templates:
        final template =
            await StorageService.templateRepository?.getTemplateById(id);
        return template == null
            ? null
            : SyncRecord(
                collection: collection,
                id: id,
                payload: template.toJson(),
                updatedAt: template.updatedAt,
              );

      case SyncCollection.themes:
        final raw = StorageService.getAllCustomThemesRaw()[id];
        return raw == null
            ? null
            : SyncRecord(
                collection: collection,
                id: id,
                payload: {'json': raw},
                updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
              );

      default:
        return null;
    }
  }

  /// Writes a record received from the server.
  ///
  /// Returns false for anything unrecognised -- a collection added by a newer
  /// version of the app -- so an older client skips it instead of crashing.
  Future<bool> applyRemote(SyncRecord record) async {
    return SyncQueue.applyingRemote(() async {
      try {
        if (record.deleted) {
          await _applyTombstone(record);
          return true;
        }
        final payload = record.payload;
        if (payload == null) return false;

        switch (record.collection) {
          case SyncCollection.todos:
            await StorageService.saveTodo(Todo.fromJson(payload));
          case SyncCollection.notes:
            await _applyNote(record, payload);
          case SyncCollection.events:
            await StorageService.saveEvent(Event.fromJson(payload));
          case SyncCollection.noteFolders:
            await StorageService.saveNoteFolder(NoteFolder.fromJson(payload));
          case SyncCollection.folders:
            await _applyFolder(Folder.fromJson(payload));
          case SyncCollection.templates:
            await _applyTemplate(FolderTemplate.fromJson(payload));
          case SyncCollection.themes:
            final raw = payload['json'];
            if (raw is String) {
              await StorageService.saveCustomTheme(record.id, raw);
            }
          default:
            return false;
        }
        return true;
      } catch (e, st) {
        debugPrint(
          '[Sync] Could not apply ${record.collection}/${record.id}: $e\n$st',
        );
        return false;
      }
    });
  }

  /// Notes are the one thing worth protecting from a clean overwrite.
  ///
  /// A task loses a due date; a note can lose an afternoon of writing. When the
  /// incoming version differs from what is here, the local text is written into
  /// the history the app already keeps, so the edit that lost is still
  /// reachable from the note's history sheet rather than gone.
  Future<void> _applyNote(SyncRecord record, Map<String, dynamic> payload) async {
    final incoming = Note.fromJson(payload);
    final existing = StorageService.getNote(record.id);

    if (existing != null &&
        existing.content != incoming.content &&
        existing.content.trim().isNotEmpty) {
      try {
        await StorageService.saveNoteHistoryEntry(
          NoteHistoryEntry(
            noteId: record.id,
            contentBefore: existing.content,
            contentAfter: incoming.content,
            timestamp: DateTime.now(),
          ),
        );
      } catch (e) {
        // History is a safety net, not a precondition. Losing it must not
        // block the note itself from syncing.
        debugPrint('[Sync] Could not record history for ${record.id}: $e');
      }
    }

    await StorageService.saveNote(incoming);
  }

  Future<void> _applyFolder(Folder folder) async {
    final repo = StorageService.folderRepository;
    if (repo == null) return;
    final existing = await repo.getFolderById(folder.id);
    if (existing == null) {
      await repo.createFolder(folder);
    } else {
      await repo.updateFolder(folder);
    }
  }

  Future<void> _applyTemplate(FolderTemplate template) async {
    final repo = StorageService.templateRepository;
    if (repo == null) return;
    final existing = await repo.getTemplateById(template.id);
    if (existing == null) {
      await repo.createTemplate(template);
    } else {
      await repo.updateTemplate(template);
    }
  }

  Future<void> _applyTombstone(SyncRecord record) async {
    switch (record.collection) {
      case SyncCollection.todos:
        await StorageService.permanentlyDeleteTodo(record.id);
      case SyncCollection.notes:
        await StorageService.permanentlyDeleteNote(record.id);
      case SyncCollection.events:
        await StorageService.permanentlyDeleteEvent(record.id);
      case SyncCollection.noteFolders:
        await StorageService.deleteNoteFolder(record.id);
      case SyncCollection.folders:
        await StorageService.folderRepository?.deleteFolder(record.id);
      case SyncCollection.templates:
        await StorageService.templateRepository?.deleteTemplate(record.id);
      case SyncCollection.themes:
        await StorageService.deleteCustomTheme(record.id);
    }
  }

  /// Everything currently stored, as ids mapped to their own timestamps. Used
  /// to seed the outbox when sync is first switched on.
  Future<Map<String, DateTime>> baselineFor(String collection) async {
    final records = await readAll(collection);
    return {for (final r in records) r.id: r.updatedAt};
  }

  /// Only for logging: a payload's rough size, to explain a slow sync.
  static int payloadBytes(SyncRecord record) =>
      record.payload == null ? 0 : jsonEncode(record.payload).length;
}
