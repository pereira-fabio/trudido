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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/folder.dart';
import '../models/note.dart';
import '../models/note_folder.dart';
import '../models/todo.dart';
import '../repositories/hive_folder_repository.dart';
import '../repositories/note_folder_repository.dart';
import '../repositories/notes_repository.dart';
import '../repositories/task_repository.dart';
import '../services/storage_service.dart';
import '../services/sync/sync_service.dart';

/// State for the browser build.
///
/// Deliberately a small graph of its own rather than the app's provider set:
/// that one reaches notifications, home-screen widgets and device calendar
/// sync, none of which exist here. The repositories underneath are the same
/// ones the phone uses, so the data and its rules are shared -- only the
/// wiring above them differs.

final taskRepositoryProvider = Provider((ref) => TaskRepository());

final noteFolderRepositoryProvider = Provider((ref) => NoteFolderRepository());

final notesRepositoryProvider = Provider(
  (ref) => NotesRepository(ref.watch(noteFolderRepositoryProvider)),
);

final folderRepositoryProvider = Provider<HiveFolderRepository?>(
  (ref) => StorageService.folderRepository,
);

/// Bumped after anything writes, to make the lists re-read.
final dataVersionProvider = StateProvider<int>((ref) => 0);

void invalidateData(WidgetRef ref) {
  ref.read(dataVersionProvider.notifier).state++;
}

final tasksProvider = FutureProvider<List<Todo>>((ref) async {
  ref.watch(dataVersionProvider);
  await StorageService.waitTodosReady();
  final todos = await StorageService.getAllTodosAsync();
  return todos.where((t) => !t.isDeleted).toList();
});

final notesListProvider = FutureProvider<List<Note>>((ref) async {
  ref.watch(dataVersionProvider);
  await StorageService.waitNotesReady();
  // Through the repository, not StorageService: it is what decrypts vault
  // notes, and skipping it would show ciphertext as a note body.
  final notes = await ref.watch(notesRepositoryProvider).getAllNotes();
  // Pinned first, then most recently edited: the same order the phone shows.
  notes.sort((a, b) {
    if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
    return b.updatedAt.compareTo(a.updatedAt);
  });
  return notes;
});

final foldersProvider = FutureProvider<List<Folder>>((ref) async {
  ref.watch(dataVersionProvider);
  final repository = StorageService.folderRepository;
  if (repository == null) return const [];
  return repository.getFoldersSorted();
});

final noteFoldersProvider = FutureProvider<List<NoteFolder>>((ref) async {
  ref.watch(dataVersionProvider);
  await StorageService.waitNoteFoldersReady();
  return StorageService.getAllNoteFolders();
});

/// Live sync status, so the header can show what is happening.
final syncStatusProvider = StreamProvider<SyncStatus>(
  (ref) => SyncService.instance.statusStream,
);

/// Which folder the task list is filtered to; null means all.
final selectedFolderProvider = StateProvider<String?>((ref) => null);

/// Which note folder the note list is filtered to; null means all.
final selectedNoteFolderProvider = StateProvider<String?>((ref) => null);

final searchQueryProvider = StateProvider<String>((ref) => '');
