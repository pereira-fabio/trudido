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

import 'package:flutter/foundation.dart';

/// Platform checks that are safe in a browser.
///
/// `dart:io`'s `Platform` cannot be compiled for web at all -- importing it
/// anywhere reachable fails the build -- so these come from
/// `flutter/foundation` instead, which works on every target.
///
/// The `!kIsWeb` guards matter: `defaultTargetPlatform` reports the *host*, so
/// a browser on an Android phone answers `TargetPlatform.android`. Without
/// them, the web build would try to call Android method channels that are not
/// there.
class AppPlatform {
  const AppPlatform._();

  /// True in a browser, whatever the underlying device.
  static bool get isWeb => kIsWeb;

  /// True only for the native Android app, never for a browser on Android.
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// True where a real filesystem exists, which is what most of the native
  /// features here actually depend on.
  static bool get hasFileSystem => !kIsWeb;
}
