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

import '../services/storage_service.dart';
import '../services/sync/sync_config.dart';
import '../services/sync/sync_service.dart';
import 'web_notes_view.dart';
import 'web_sync_panel.dart';
import 'web_tasks_view.dart';

const _seed = Color(0xFF5B7C99);

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.comfortable,
  );
}

class TrudidoWebApp extends StatelessWidget {
  const TrudidoWebApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Trudido',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: const _Bootstrap(),
  );
}

/// Opens storage before anything reads it.
///
/// Hive uses IndexedDB in a browser, so the same StorageService the phone uses
/// works here untouched -- which is the whole reason this build can share the
/// repositories rather than reimplement them.
class _Bootstrap extends ConsumerStatefulWidget {
  const _Bootstrap();

  @override
  ConsumerState<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends ConsumerState<_Bootstrap> {
  Future<void>? _startup;

  @override
  void initState() {
    super.initState();
    _startup = _start();
  }

  Future<void> _start() async {
    await StorageService.init();
    await SyncService.instance.init();
    if (SyncConfig.isConfigured) {
      // A browser tab has no "resumed" event to sync on, so it polls instead.
      SyncService.instance.startPeriodic();
      unawaited(SyncService.instance.sync());
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _startup,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      }
      if (snapshot.hasError) {
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 40),
                  const SizedBox(height: 12),
                  const Text('Could not open local storage.'),
                  const SizedBox(height: 8),
                  Text(
                    '${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Private browsing blocks IndexedDB in some browsers, '
                    'which is the usual cause.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return const WebShell();
    },
  );
}

class WebShell extends ConsumerStatefulWidget {
  const WebShell({super.key});

  @override
  ConsumerState<WebShell> createState() => _WebShellState();
}

class _WebShellState extends ConsumerState<WebShell> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.check_circle_outline, selected: Icons.check_circle, label: 'Tasks'),
    (icon: Icons.description_outlined, selected: Icons.description, label: 'Notes'),
    (icon: Icons.sync_outlined, selected: Icons.sync, label: 'Sync'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;

    final body = switch (_index) {
      0 => const WebTasksView(),
      1 => const WebNotesView(),
      _ => const WebSyncPanel(),
    };

    if (!wide) {
      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selected),
                label: d.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Icon(Icons.task_alt, size: 28),
            ),
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: SafeArea(child: body)),
        ],
      ),
    );
  }
}
