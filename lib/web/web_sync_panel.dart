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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sync/sync_config.dart';
import '../services/sync/sync_service.dart';
import 'web_providers.dart';

/// Sync setup and status for the browser build.
class WebSyncPanel extends ConsumerStatefulWidget {
  const WebSyncPanel({super.key});

  @override
  ConsumerState<WebSyncPanel> createState() => _WebSyncPanelState();
}

class _WebSyncPanelState extends ConsumerState<WebSyncPanel> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    _url.text = SyncConfig.serverUrl.isEmpty
        // Served from the same origin as the API in the usual deployment, so
        // this is right far more often than it is wrong.
        ? Uri.base.origin
        : SyncConfig.serverUrl;
    _token.text = SyncConfig.token;
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await SyncService.instance.testConnection(
        url: _url.text.trim(),
        token: _token.text.trim(),
      );
      await SyncService.instance.enable(
        serverUrl: _url.text.trim(),
        token: _token.text.trim(),
      );
      final result = await SyncService.instance.sync();
      if (!mounted) return;
      invalidateData(ref);
      setState(() {
        _ok = result.ok;
        _message = result.ok
            ? 'Connected. ${result.pulled} received, ${result.pushed} sent.'
            : result.error;
      });
      SyncService.instance.startPeriodic();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _message = '$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    final result = await SyncService.instance.sync();
    if (!mounted) return;
    invalidateData(ref);
    setState(() {
      _busy = false;
      _ok = result.ok;
      _message = result.ok
          ? '${result.pulled} received, ${result.pushed} sent'
                '${result.conflicts > 0 ? ', ${result.conflicts} conflicts resolved' : ''}.'
          : result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = ref.watch(syncStatusProvider);
    final configured = SyncConfig.isConfigured;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Sync', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'This page keeps its own copy of your data in the browser and syncs '
          'it with your server, exactly as the phone does. Closing the tab '
          'loses nothing.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _url,
          decoration: const InputDecoration(
            labelText: 'Server address',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _token,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Access token',
            helperText: 'Leave empty if the server has no token set.',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.key_outlined),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _connect,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: Text(configured ? 'Reconnect' : 'Connect'),
            ),
            if (configured) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _syncNow,
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
              ),
            ],
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 16),
          Text(
            _message!,
            style: TextStyle(
              color: _ok ? theme.colorScheme.primary : theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 24),
        status.maybeWhen(
          data: (value) => value.phase == SyncPhase.idle
              ? const SizedBox.shrink()
              : Card(
                  child: ListTile(
                    leading: Icon(
                      value.error != null
                          ? Icons.error_outline
                          : value.isRunning
                          ? Icons.sync
                          : Icons.check_circle_outline,
                    ),
                    title: Text(
                      value.error ??
                          (value.isRunning
                              ? 'Syncing…'
                              : '${value.pulled} received, ${value.pushed} sent'),
                    ),
                    subtitle: value.pending > 0
                        ? Text('${value.pending} waiting to send')
                        : null,
                  ),
                ),
          orElse: () => const SizedBox.shrink(),
        ),
        const SizedBox(height: 24),
        Text('What this build does not do', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '• Notes written in the phone’s rich editor open read-only, '
          'so saving plain text cannot discard their formatting or images.\n'
          '• Attachments are not shown.\n'
          '• Reminders, home-screen widgets and device calendar sync are '
          'features of the Android app.\n'
          '• The vault stays on the phone: its key is per-device, so these '
          'notes cannot be decrypted here.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
