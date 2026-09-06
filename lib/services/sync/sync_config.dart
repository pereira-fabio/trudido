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

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Where sync stores its settings and its place in the server's history.
///
/// The token lives in SharedPreferences rather than secure storage on purpose:
/// it guards a box on your own network, it has to be readable on web where
/// secure storage is only localStorage anyway, and treating it as a secret
/// would imply a protection this cannot actually offer. The vault key, which
/// genuinely is a secret, stays in secure storage.
class SyncConfig {
  static const _kEnabled = 'sync_enabled';
  static const _kServerUrl = 'sync_server_url';
  static const _kToken = 'sync_token';
  static const _kDeviceId = 'sync_device_id';
  static const _kCursor = 'sync_cursor';
  static const _kLastSyncAt = 'sync_last_at';
  static const _kLastError = 'sync_last_error';
  static const _kAutoSync = 'sync_auto';
  static const _kSyncMedia = 'sync_media';

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    // Generated once and kept for the life of the install. It breaks ties when
    // two devices report the same edit time, so it must be stable.
    if ((_prefs!.getString(_kDeviceId) ?? '').isEmpty) {
      await _prefs!.setString(_kDeviceId, const Uuid().v4());
    }
  }

  static bool get isReady => _prefs != null;

  static bool get enabled => _prefs?.getBool(_kEnabled) ?? false;
  static Future<void> setEnabled(bool value) async =>
      _prefs?.setBool(_kEnabled, value);

  /// Normalised to have no trailing slash, so callers can append paths freely.
  static String get serverUrl {
    final raw = _prefs?.getString(_kServerUrl) ?? '';
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  static Future<void> setServerUrl(String value) async =>
      _prefs?.setString(_kServerUrl, value.trim());

  static String get token => _prefs?.getString(_kToken) ?? '';
  static Future<void> setToken(String value) async =>
      _prefs?.setString(_kToken, value.trim());

  static String get deviceId => _prefs?.getString(_kDeviceId) ?? '';

  /// Highest server revision this device has already applied.
  static int get cursor => _prefs?.getInt(_kCursor) ?? 0;
  static Future<void> setCursor(int value) async =>
      _prefs?.setInt(_kCursor, value);

  static DateTime? get lastSyncAt {
    final raw = _prefs?.getInt(_kLastSyncAt);
    return raw == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(raw);
  }

  static Future<void> setLastSyncAt(DateTime value) async =>
      _prefs?.setInt(_kLastSyncAt, value.millisecondsSinceEpoch);

  static String? get lastError => _prefs?.getString(_kLastError);
  static Future<void> setLastError(String? value) async {
    if (value == null) {
      await _prefs?.remove(_kLastError);
    } else {
      await _prefs?.setString(_kLastError, value);
    }
  }

  static bool get autoSync => _prefs?.getBool(_kAutoSync) ?? true;
  static Future<void> setAutoSync(bool value) async =>
      _prefs?.setBool(_kAutoSync, value);

  /// Attachments can be large and are the one thing worth leaving behind on a
  /// metered connection, so they are separately switchable.
  static bool get syncMedia => _prefs?.getBool(_kSyncMedia) ?? true;
  static Future<void> setSyncMedia(bool value) async =>
      _prefs?.setBool(_kSyncMedia, value);

  static bool get isConfigured => enabled && serverUrl.isNotEmpty;

  /// Forgets our place in the server's history without touching local data, so
  /// the next sync re-reads everything. The repair for a cursor that has
  /// drifted out of step.
  static Future<void> resetCursor() async => setCursor(0);
}
