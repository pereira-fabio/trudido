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
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/note.dart';
import '../services/storage_service.dart';
import '../services/sync/sync_service.dart';
import 'web_common.dart';
import 'web_providers.dart';

/// A two-pane note view: list on the left, editor on the right.
class WebNotesView extends ConsumerStatefulWidget {
  const WebNotesView({super.key});

  @override
  ConsumerState<WebNotesView> createState() => _WebNotesViewState();
}

class _WebNotesViewState extends ConsumerState<WebNotesView> {
  String? _openNoteId;

  Future<void> _create() async {
    final note = Note(title: 'Untitled', content: '');
    await StorageService.saveNote(note);
    invalidateData(ref);
    setState(() => _openNoteId = note.id);
    unawaited(SyncService.instance.sync());
  }

  @override
  Widget build(BuildContext context) {
    final notes = ref.watch(notesListProvider);
    final query = ref.watch(searchQueryProvider).toLowerCase();
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final list = notes.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('Could not load notes: $error')),
      data: (all) {
        final filtered = query.isEmpty
            ? all
            : all
                  .where(
                    (n) =>
                        n.title.toLowerCase().contains(query) ||
                        n.content.toLowerCase().contains(query),
                  )
                  .toList();
        if (filtered.isEmpty) {
          return const WebEmpty(
            icon: Icons.description_outlined,
            message: 'No notes.',
          );
        }
        return ListView.builder(
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final note = filtered[index];
            return ListTile(
              selected: note.id == _openNoteId,
              leading: note.isPinned
                  ? const Icon(Icons.push_pin, size: 18)
                  : const Icon(Icons.notes, size: 18),
              title: Text(
                note.title.isEmpty ? 'Untitled' : note.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _preview(note.content),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                DateFormat.MMMd().format(note.updatedAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () => setState(() => _openNoteId = note.id),
            );
          },
        );
      },
    );

    final editor = _openNoteId == null
        ? const WebEmpty(
            icon: Icons.edit_note,
            message: 'Select a note, or create one.',
          )
        : WebNoteEditor(
            key: ValueKey(_openNoteId),
            noteId: _openNoteId!,
            onDeleted: () => setState(() => _openNoteId = null),
          );

    final header = WebHeader(
      title: 'Notes',
      trailing: IconButton(
        tooltip: 'New note',
        icon: const Icon(Icons.add),
        onPressed: _create,
      ),
    );

    if (!wide) {
      return Column(
        children: [
          header,
          Expanded(child: _openNoteId == null ? list : editor),
        ],
      );
    }

    return Column(
      children: [
        header,
        Expanded(
          child: Row(
            children: [
              SizedBox(width: 320, child: list),
              const VerticalDivider(width: 1),
              Expanded(child: editor),
            ],
          ),
        ),
      ],
    );
  }

  /// A one-line preview, with Quill's delta JSON reduced to its text.
  static String _preview(String content) {
    final text = _plainText(content);
    return text.replaceAll('\n', ' ').trim();
  }
}

/// Notes written in the phone's rich editor are stored as a Quill delta rather
/// than markdown. Rendering that JSON verbatim would be unreadable, so the
/// text is pulled out of it for display.
String _plainText(String content) {
  final trimmed = content.trimLeft();
  if (!trimmed.startsWith('[') && !trimmed.startsWith('{')) return content;
  try {
    final decoded = jsonDecode(content);
    if (decoded is! List) return content;
    final buffer = StringBuffer();
    for (final op in decoded) {
      if (op is Map && op['insert'] is String) buffer.write(op['insert']);
    }
    final text = buffer.toString();
    return text.isEmpty ? content : text;
  } catch (_) {
    return content;
  }
}

/// True when the content is a Quill delta rather than markdown, in which case
/// this build can show it but must not offer to edit it: saving markdown over
/// a delta would destroy the note's formatting on the phone.
bool _isQuillDelta(String content) {
  final trimmed = content.trimLeft();
  if (!trimmed.startsWith('[')) return false;
  try {
    final decoded = jsonDecode(content);
    return decoded is List &&
        decoded.every((op) => op is Map && op.containsKey('insert'));
  } catch (_) {
    return false;
  }
}

class WebNoteEditor extends ConsumerStatefulWidget {
  final String noteId;
  final VoidCallback onDeleted;

  const WebNoteEditor({super.key, required this.noteId, required this.onDeleted});

  @override
  ConsumerState<WebNoteEditor> createState() => _WebNoteEditorState();
}

class _WebNoteEditorState extends ConsumerState<WebNoteEditor> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  Timer? _saveTimer;
  bool _readOnly = false;
  bool _preview = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final note = StorageService.getNote(widget.noteId);
    _readOnly = note != null && _isQuillDelta(note.content);
    _title = TextEditingController(text: note?.title ?? '');
    _body = TextEditingController(
      text: note == null
          ? ''
          : (_readOnly ? _plainText(note.content) : note.content),
    );
    _title.addListener(_scheduleSave);
    _body.addListener(_scheduleSave);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Flushed synchronously, so closing a note never loses the last keystrokes.
    if (_dirty) _save();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    if (_readOnly) return;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
  }

  Future<void> _save() async {
    if (_readOnly || !_dirty) return;
    final note = StorageService.getNote(widget.noteId);
    if (note == null) return;
    note.title = _title.text;
    note.content = _body.text;
    note.updatedAt = DateTime.now();
    await StorageService.saveNote(note);
    _dirty = false;
    if (mounted) invalidateData(ref);
    unawaited(SyncService.instance.sync());
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move note to bin?'),
        content: const Text('You can restore it from the bin on your phone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Move to bin'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _saveTimer?.cancel();
    _dirty = false;
    await StorageService.deleteNote(widget.noteId);
    invalidateData(ref);
    unawaited(SyncService.instance.sync());
    widget.onDeleted();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _title,
                  readOnly: _readOnly,
                  style: theme.textTheme.titleLarge,
                  decoration: const InputDecoration(
                    hintText: 'Title',
                    border: InputBorder.none,
                  ),
                ),
              ),
              IconButton(
                tooltip: _preview ? 'Edit' : 'Preview',
                icon: Icon(_preview ? Icons.edit : Icons.visibility),
                onPressed: () => setState(() => _preview = !_preview),
              ),
              IconButton(
                tooltip: 'Move to bin',
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete,
              ),
            ],
          ),
        ),
        if (_readOnly)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Read-only here. This note was written in the rich editor on the '
              'phone, and saving it as plain text would discard its formatting '
              'and any images.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const Divider(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _preview || _readOnly
                ? Markdown(data: _body.text, selectable: true)
                : TextField(
                    controller: _body,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: 'Write in markdown…',
                      border: InputBorder.none,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
