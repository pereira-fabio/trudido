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

import '../services/sync/sync_config.dart';
import '../services/sync/sync_queue.dart';
import '../services/sync/sync_service.dart';

/// Settings for syncing to a self-hosted server.
class SyncSettingsScreen extends ConsumerStatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  ConsumerState<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends ConsumerState<SyncSettingsScreen> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();

  StreamSubscription<SyncStatus>? _statusSub;
  SyncStatus _status = const SyncStatus();

  bool _enabled = false;
  bool _autoSync = true;
  bool _syncMedia = true;
  bool _obscureToken = true;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    _load();
    _statusSub = SyncService.instance.statusStream.listen((status) {
      if (mounted) setState(() => _status = status);
    });
  }

  Future<void> _load() async {
    await SyncConfig.init();
    if (!mounted) return;
    setState(() {
      _urlController.text = SyncConfig.serverUrl;
      _tokenController.text = SyncConfig.token;
      _enabled = SyncConfig.enabled;
      _autoSync = SyncConfig.autoSync;
      _syncMedia = SyncConfig.syncMedia;
      _status = SyncService.instance.status;
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  String get _url => _urlController.text.trim();

  Future<void> _testConnection() async {
    if (_url.isEmpty) {
      setState(() {
        _testOk = false;
        _testResult = 'Enter the server address first.';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      await SyncService.instance.testConnection(
        url: _url,
        token: _tokenController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testResult = 'Connected.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = '$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _toggleEnabled(bool value) async {
    if (value) {
      if (_url.isEmpty) {
        _snack('Enter the server address first.');
        return;
      }
      await SyncService.instance.enable(
        serverUrl: _url,
        token: _tokenController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _enabled = true);
      _snack('Sync on. Your existing data will upload on the next sync.');
    } else {
      await SyncService.instance.disable();
      if (!mounted) return;
      setState(() => _enabled = false);
      _snack('Sync off. Nothing was deleted.');
    }
  }

  Future<void> _syncNow() async {
    // Save any edits sitting in the fields, so the button uses what is on
    // screen rather than what was last committed.
    await SyncConfig.setServerUrl(_url);
    await SyncConfig.setToken(_tokenController.text.trim());

    final result = await SyncService.instance.sync();
    if (!mounted) return;
    _snack(
      result.ok
          ? 'Synced. ${result.pulled} in, ${result.pushed} out'
              '${result.conflicts > 0 ? ', ${result.conflicts} conflicts resolved' : ''}.'
          : result.error ?? 'Sync failed.',
    );
  }

  Future<void> _resync() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sync everything again?'),
        content: const Text(
          'Re-reads the whole server history and re-offers every local record.\n\n'
          'Nothing is deleted. Use this if the two ever look out of step — '
          'after restoring the server from a backup, for instance.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sync everything'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final result = await SyncService.instance.resync();
    if (!mounted) return;
    _snack(
      result.ok
          ? 'Full sync done. ${result.pulled} in, ${result.pushed} out.'
          : result.error ?? 'Sync failed.',
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _status.isRunning;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Keep your tasks and notes on a server you run. Trudido stays '
              'offline-first: everything works with the server unreachable, '
              'and syncs when it comes back.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          _header(context, 'Server'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: 'http://192.168.1.10:8001',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _tokenController,
              obscureText: _obscureToken,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Access token',
                helperText: 'Leave empty if the server has no token set.',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key_outlined),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureToken
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  tooltip: _obscureToken ? 'Show token' : 'Hide token',
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check),
                  label: const Text('Test connection'),
                ),
                const SizedBox(width: 12),
                if (_testResult != null)
                  Expanded(
                    child: Text(
                      _testResult!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _testOk
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 8),
          SwitchListTile(
            value: _enabled,
            onChanged: _toggleEnabled,
            secondary: const Icon(Icons.sync),
            title: const Text('Sync with this server'),
            subtitle: Text(
              _enabled
                  ? 'On. Changes are tracked and sent.'
                  : 'Off. Everything stays on this device.',
            ),
          ),

          if (_enabled) ...[
            SwitchListTile(
              value: _autoSync,
              onChanged: (v) async {
                await SyncConfig.setAutoSync(v);
                setState(() => _autoSync = v);
              },
              secondary: const Icon(Icons.autorenew),
              title: const Text('Sync automatically'),
              subtitle: const Text('When the app returns to the foreground'),
            ),
            SwitchListTile(
              value: _syncMedia,
              onChanged: (v) async {
                await SyncConfig.setSyncMedia(v);
                setState(() => _syncMedia = v);
              },
              secondary: const Icon(Icons.perm_media_outlined),
              title: const Text('Sync attachments'),
              subtitle: const Text(
                'Images, audio and video in notes. Off saves bandwidth; '
                'embeds will not open on other devices.',
              ),
            ),

            _header(context, 'Status'),
            _statusTile(theme),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: running ? null : _syncNow,
                      icon: running
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                      label: Text(running ? 'Syncing…' : 'Sync now'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: running ? null : _resync,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Sync all'),
                  ),
                ],
              ),
            ),
          ],

          _header(context, 'This device'),
          ListTile(
            leading: const Icon(Icons.smartphone_outlined),
            title: const Text('Device ID'),
            subtitle: Text(
              SyncConfig.isReady && SyncConfig.deviceId.isNotEmpty
                  ? SyncConfig.deviceId
                  : 'Not assigned yet',
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Your vault stays encrypted on the server — it is stored as '
              'ciphertext and cannot be read there.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusTile(ThemeData theme) {
    final error = _status.error;
    final last = _status.lastSyncAt ?? SyncConfig.lastSyncAt;

    final IconData icon;
    final Color color;
    final String title;

    if (_status.isRunning) {
      icon = Icons.sync;
      color = theme.colorScheme.primary;
      title = switch (_status.phase) {
        SyncPhase.connecting => 'Connecting…',
        SyncPhase.pulling => 'Receiving changes…',
        SyncPhase.pushing => 'Sending changes…',
        _ => 'Syncing…',
      };
    } else if (error != null) {
      icon = Icons.error_outline;
      color = theme.colorScheme.error;
      title = 'Last sync failed';
    } else if (last != null) {
      icon = Icons.check_circle_outline;
      color = theme.colorScheme.primary;
      title = 'Last synced ${_relative(last)}';
    } else {
      icon = Icons.schedule;
      color = theme.colorScheme.onSurfaceVariant;
      title = 'Not synced yet';
    }

    final pending = _status.pending > 0
        ? _status.pending
        : (SyncQueue.isOpen ? SyncQueue.length : 0);

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            Text(error, style: TextStyle(color: theme.colorScheme.error))
          else if (_status.pulled > 0 || _status.pushed > 0)
            Text(
              '${_status.pulled} received, ${_status.pushed} sent'
              '${_status.conflicts > 0 ? ', ${_status.conflicts} conflicts resolved' : ''}',
            ),
          if (pending > 0)
            Text('$pending change${pending == 1 ? '' : 's'} waiting to send'),
        ],
      ),
      isThreeLine: error != null || pending > 0,
    );
  }

  Widget _header(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  static String _relative(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }
}
