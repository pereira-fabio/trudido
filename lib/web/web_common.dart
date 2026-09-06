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

import 'web_providers.dart';

class WebHeader extends ConsumerWidget {
  final String title;
  final Widget? trailing;

  const WebHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
    child: Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(width: 24),
        Expanded(
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search…',
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                ref.read(searchQueryProvider.notifier).update(value),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

class WebEmpty extends StatelessWidget {
  final IconData icon;
  final String message;

  const WebEmpty({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: muted),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(color: muted)),
        ],
      ),
    );
  }
}
