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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/todo.dart';
import '../services/storage_service.dart';
import '../services/sync/sync_service.dart';
import 'web_common.dart';
import 'web_providers.dart';

class WebTasksView extends ConsumerStatefulWidget {
  const WebTasksView({super.key});

  @override
  ConsumerState<WebTasksView> createState() => _WebTasksViewState();
}

class _WebTasksViewState extends ConsumerState<WebTasksView> {
  final _newTaskController = TextEditingController();
  bool _showCompleted = false;

  @override
  void dispose() {
    _newTaskController.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _newTaskController.text.trim();
    if (text.isEmpty) return;
    await StorageService.saveTodo(
      Todo(text: text, folderId: ref.read(selectedFolderProvider)),
    );
    _newTaskController.clear();
    invalidateData(ref);
    unawaited(SyncService.instance.sync());
  }

  Future<void> _toggle(Todo todo) async {
    await StorageService.updateTodo(
      todo.copyWith(
        isCompleted: !todo.isCompleted,
        completedAt: todo.isCompleted ? null : DateTime.now(),
      ),
    );
    invalidateData(ref);
    unawaited(SyncService.instance.sync());
  }

  Future<void> _rename(Todo todo) async {
    final controller = TextEditingController(text: todo.text);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit task'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    await StorageService.updateTodo(todo.copyWith(text: result.trim()));
    invalidateData(ref);
    unawaited(SyncService.instance.sync());
  }

  Future<void> _delete(Todo todo) async {
    await StorageService.deleteTodo(todo.id);
    invalidateData(ref);
    unawaited(SyncService.instance.sync());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Moved to bin'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await StorageService.restoreTodo(todo.id);
            invalidateData(ref);
            unawaited(SyncService.instance.sync());
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(tasksProvider);
    final folders = ref.watch(foldersProvider);
    final selected = ref.watch(selectedFolderProvider);
    final query = ref.watch(searchQueryProvider).toLowerCase();

    return Column(
      children: [
        WebHeader(
          title: 'Tasks',
          trailing: IconButton(
            tooltip: _showCompleted ? 'Hide completed' : 'Show completed',
            icon: Icon(
              _showCompleted ? Icons.visibility_off : Icons.visibility,
            ),
            onPressed: () => setState(() => _showCompleted = !_showCompleted),
          ),
        ),
        folders.maybeWhen(
          data: (list) => list.isEmpty
              ? const SizedBox.shrink()
              : SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: const Text('All'),
                          selected: selected == null,
                          onSelected: (_) => ref
                              .read(selectedFolderProvider.notifier)
                              .update(null),
                        ),
                      ),
                      for (final folder in list)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(folder.name),
                            selected: selected == folder.id,
                            onSelected: (_) => ref
                                .read(selectedFolderProvider.notifier)
                                .update(selected == folder.id ? null : folder.id),
                          ),
                        ),
                    ],
                  ),
                ),
          orElse: () => const SizedBox.shrink(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _newTaskController,
            decoration: InputDecoration(
              hintText: 'Add a task…',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.add),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: _add,
              ),
            ),
            onSubmitted: (_) => _add(),
          ),
        ),
        Expanded(
          child: tasks.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text('Could not load tasks: $error')),
            data: (all) {
              var list = all;
              if (selected != null) {
                list = list.where((t) => t.folderId == selected).toList();
              }
              if (query.isNotEmpty) {
                list = list
                    .where((t) => t.text.toLowerCase().contains(query))
                    .toList();
              }
              if (!_showCompleted) {
                list = list.where((t) => !t.isCompleted).toList();
              }
              list.sort((a, b) {
                if (a.isCompleted != b.isCompleted) {
                  return a.isCompleted ? 1 : -1;
                }
                final aDue = a.dueDate, bDue = b.dueDate;
                if (aDue != null && bDue != null) return aDue.compareTo(bDue);
                if (aDue != null) return -1;
                if (bDue != null) return 1;
                return b.createdAt.compareTo(a.createdAt);
              });

              if (list.isEmpty) {
                return const WebEmpty(
                  icon: Icons.check_circle_outline,
                  message: 'Nothing here.',
                );
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final todo = list[index];
                  return _TaskTile(
                    todo: todo,
                    onToggle: () => _toggle(todo),
                    onEdit: () => _rename(todo),
                    onDelete: () => _delete(todo),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  final Todo todo;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TaskTile({
    required this.todo,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final due = todo.dueDate;
    final overdue =
        due != null && !todo.isCompleted && due.isBefore(DateTime.now());

    return ListTile(
      leading: Checkbox(value: todo.isCompleted, onChanged: (_) => onToggle()),
      title: Text(
        todo.text,
        style: todo.isCompleted
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: theme.colorScheme.onSurfaceVariant,
              )
            : null,
      ),
      subtitle: due == null
          ? (todo.notes?.isNotEmpty == true
                ? Text(
                    todo.notes!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null)
          : Text(
              DateFormat.yMMMd().add_Hm().format(due),
              style: TextStyle(
                color: overdue ? theme.colorScheme.error : null,
              ),
            ),
      onTap: onEdit,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Move to bin',
        onPressed: onDelete,
      ),
    );
  }
}
