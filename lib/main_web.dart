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

/// Entry point for the browser build.
///
///     flutter build web --release -t lib/main_web.dart
///
/// Separate from main.dart on purpose. Only code reachable from the entry
/// point is compiled, and roughly a dozen files in the Android app import
/// dart:io -- legal there, fatal for web. Keeping this entry point clear of
/// them means the browser build needs no changes to the app those files
/// belong to, and cannot regress it.
///
/// What is shared is everything that matters: the models, Hive storage (which
/// is IndexedDB here), the repositories, and the whole sync client. The data
/// and its rules are the same; only the interface above them differs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web/web_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: TrudidoWebApp()));
}
