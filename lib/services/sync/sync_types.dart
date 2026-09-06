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

/// Shared vocabulary between the sync client and the self-hosted server.
///
/// The wire format is deliberately generic: the server stores opaque JSON
/// documents keyed by (collection, id) and never parses a payload. Adding a
/// model later is a client-side change only.
library;

/// The collections that sync. These strings are part of the wire protocol and
/// are persisted in the outbox, so they must not be renamed without a
/// migration.
class SyncCollection {
  static const String todos = 'todos';
  static const String notes = 'notes';
  static const String events = 'events';
  static const String folders = 'folders';
  static const String noteFolders = 'note_folders';
  static const String templates = 'templates';
  static const String themes = 'themes';

  /// App preferences travel as a single document in this collection, because
  /// they are a flat key/value blob rather than a set of addressable records.
  static const String settings = 'settings';

  static const List<String> all = [
    todos,
    notes,
    events,
    folders,
    noteFolders,
    templates,
    themes,
    settings,
  ];
}

/// What happened to a record locally. The server only distinguishes "content"
/// from "tombstone", but the outbox keeps the finer distinction so the client
/// can skip fetching a payload it knows is gone.
enum SyncOp {
  /// Record was created or modified; the payload is read at drain time.
  upsert,

  /// Record was removed outright (bin purge, "delete forever", clear-all).
  /// Soft deletes are an [upsert] with `isDeleted: true` — they still have a
  /// payload and the other device needs it to show the item in its bin.
  delete,
}

extension SyncOpWire on SyncOp {
  String get wire => this == SyncOp.delete ? 'delete' : 'upsert';

  static SyncOp parse(String? value) =>
      value == 'delete' ? SyncOp.delete : SyncOp.upsert;
}

/// One record as it crosses the wire.
class SyncRecord {
  final String collection;
  final String id;

  /// `null` for a tombstone.
  final Map<String, dynamic>? payload;
  final DateTime updatedAt;
  final bool deleted;

  /// Server-assigned monotonic revision. Absent on records being pushed up.
  final int? rev;

  const SyncRecord({
    required this.collection,
    required this.id,
    required this.updatedAt,
    this.payload,
    this.deleted = false,
    this.rev,
  });

  Map<String, dynamic> toJson() => {
    'collection': collection,
    'id': id,
    'payload': payload,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'deleted': deleted,
  };

  static SyncRecord fromJson(Map<String, dynamic> json) => SyncRecord(
    collection: json['collection'] as String,
    id: json['id'] as String,
    payload: (json['payload'] as Map?)?.cast<String, dynamic>(),
    updatedAt: DateTime.parse(json['updated_at'] as String).toLocal(),
    deleted: json['deleted'] as bool? ?? false,
    rev: json['rev'] as int?,
  );
}

/// Why a pushed record was not accepted.
class SyncRejection {
  final String collection;
  final String id;

  /// The server's copy, which was newer. The client resolves against this.
  final SyncRecord? serverRecord;

  const SyncRejection({
    required this.collection,
    required this.id,
    this.serverRecord,
  });

  static SyncRejection fromJson(Map<String, dynamic> json) => SyncRejection(
    collection: json['collection'] as String,
    id: json['id'] as String,
    serverRecord: json['server_record'] == null
        ? null
        : SyncRecord.fromJson(
            (json['server_record'] as Map).cast<String, dynamic>(),
          ),
  );
}
