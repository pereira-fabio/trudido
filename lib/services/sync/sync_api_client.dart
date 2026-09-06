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

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'sync_types.dart';

/// Raised for anything the caller should show the user. Transport failures and
/// HTTP errors both land here so the settings screen has one thing to catch.
class SyncApiException implements Exception {
  final String message;
  final int? statusCode;

  const SyncApiException(this.message, {this.statusCode});

  /// True when retrying is pointless until the user changes something.
  bool get isAuthFailure => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// Thin HTTP wrapper over the sync server. Holds no state beyond its
/// configuration so it can be rebuilt whenever settings change.
class SyncApiClient {
  final String baseUrl;
  final String token;
  final http.Client _http;
  final Duration timeout;

  SyncApiClient({
    required this.baseUrl,
    this.token = '',
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _http = client ?? http.Client();

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (token.isNotEmpty) 'X-Trudido-Token': token,
  };

  Uri _uri(String path, [Map<String, dynamic>? query]) => Uri.parse(
    '$baseUrl/api/v1$path',
  ).replace(
    queryParameters: query?.map((k, v) => MapEntry(k, '$v')),
  );

  Never _fail(http.Response response) {
    var detail = 'HTTP ${response.statusCode}';
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) {
        detail = '${body['detail']}';
      }
    } catch (_) {
      // A non-JSON body (a proxy error page, say) is not worth parsing.
    }
    throw SyncApiException(detail, statusCode: response.statusCode);
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on SyncApiException {
      rethrow;
    } catch (e) {
      // Wrapping keeps SocketException, TimeoutException, HandshakeException
      // and the web-only variants from leaking platform types to the UI.
      throw SyncApiException('Could not reach the server: $e');
    }
  }

  /// Verifies the URL and token together. What "Test connection" calls.
  Future<bool> checkAuth() => _guard(() async {
    final response = await _http
        .get(_uri('/auth/check'), headers: _headers)
        .timeout(timeout);
    if (response.statusCode == 200) return true;
    _fail(response);
  });

  Future<Map<String, dynamic>> status() => _guard(() async {
    final response = await _http
        .get(_uri('/sync/status'), headers: _headers)
        .timeout(timeout);
    if (response.statusCode != 200) _fail(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  });

  /// One page of changes after [since].
  Future<PullResult> pull(int since, {int? limit}) => _guard(() async {
    final response = await _http
        .get(
          _uri('/sync/changes', {
            'since': since,
            if (limit != null) 'limit': limit,
          }),
          headers: _headers,
        )
        .timeout(timeout);
    if (response.statusCode != 200) _fail(response);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return PullResult(
      records: (body['records'] as List)
          .map((r) => SyncRecord.fromJson((r as Map).cast<String, dynamic>()))
          .toList(),
      cursor: body['cursor'] as int,
      hasMore: body['has_more'] as bool? ?? false,
    );
  });

  Future<PushResult> push(String deviceId, List<SyncRecord> records) =>
      _guard(() async {
        final response = await _http
            .post(
              _uri('/sync/changes'),
              headers: _headers,
              body: jsonEncode({
                'device_id': deviceId,
                'records': records.map((r) => r.toJson()).toList(),
              }),
            )
            .timeout(timeout);
        if (response.statusCode != 200) _fail(response);

        final body = jsonDecode(response.body) as Map<String, dynamic>;
        return PushResult(
          cursor: body['cursor'] as int,
          applied: body['applied'] as int? ?? 0,
          rejections: (body['rejected'] as List? ?? [])
              .map(
                (r) => SyncRejection.fromJson((r as Map).cast<String, dynamic>()),
              )
              .toList(),
        );
      });

  /// Hashes the server already holds, so the client can skip those uploads.
  Future<Set<String>> blobManifest() => _guard(() async {
    final response = await _http
        .get(_uri('/blobs/manifest'), headers: _headers)
        .timeout(timeout);
    if (response.statusCode != 200) _fail(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return {for (final b in body['blobs'] as List) b['sha256'] as String};
  });

  /// Attachments get a longer timeout than records: a video note over a home
  /// network can legitimately take minutes.
  Future<void> uploadBlob(
    String sha256,
    String filename,
    Uint8List bytes, {
    String? mime,
  }) => _guard(() async {
    final request = http.MultipartRequest('PUT', _uri('/blobs/$sha256'))
      ..headers.addAll({if (token.isNotEmpty) 'X-Trudido-Token': token})
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    final streamed = await request.send().timeout(const Duration(minutes: 10));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200) _fail(response);
  });

  Future<Uint8List> downloadBlob(String sha256) => _guard(() async {
    final response = await _http
        .get(_uri('/blobs/$sha256'), headers: _headers)
        .timeout(const Duration(minutes: 10));
    if (response.statusCode != 200) _fail(response);
    return response.bodyBytes;
  });

  void close() => _http.close();
}

class PullResult {
  final List<SyncRecord> records;
  final int cursor;
  final bool hasMore;

  const PullResult({
    required this.records,
    required this.cursor,
    required this.hasMore,
  });
}

class PushResult {
  final int cursor;
  final int applied;
  final List<SyncRejection> rejections;

  const PushResult({
    required this.cursor,
    required this.applied,
    required this.rejections,
  });
}
