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

import 'package:path/path.dart' as p;

/// How note attachments are referred to, and where they actually live.
///
/// Embeds used to store an absolute device path -- something like
/// `/data/user/0/com.trudido.app/app_flutter/media/image_1757.jpg`. That is
/// meaningless on a second device, meaningless in a browser, and breaks even on
/// the same phone if the app's data directory ever moves. New embeds store a
/// portable `trudido://media/<name>` reference instead.
///
/// Old notes are not rewritten. [resolve] takes the filename from either form,
/// so existing content keeps working untouched and no migration has to walk
/// every note's Quill delta -- which is the kind of rewrite that goes wrong
/// quietly and loses someone's writing.
class MediaRef {
  static const String scheme = 'trudido://media/';

  static String? _directory;

  /// Points the resolver at the media directory. Called once at startup;
  /// deliberately takes the path rather than reaching for path_provider, which
  /// does not exist on web.
  static void configure(String mediaDirectoryPath) {
    _directory = mediaDirectoryPath;
  }

  static bool get isConfigured => _directory != null;

  /// The media directory, or empty before [configure] has run.
  static String get directory => _directory ?? '';

  /// The bare filename, from a portable reference or a legacy absolute path.
  static String fileNameOf(String stored) {
    if (stored.startsWith(scheme)) return stored.substring(scheme.length);
    return p.basename(stored);
  }

  /// The form to store in new content and send over the wire.
  static String toPortable(String pathOrRef) => '$scheme${fileNameOf(pathOrRef)}';

  /// Absolute local path for reading the file.
  ///
  /// Resolves by filename, so a path recorded on another device -- or by this
  /// app before its data directory moved -- still finds the local copy.
  static String resolve(String stored) {
    final dir = _directory;
    if (dir == null || dir.isEmpty) return stored;
    return p.join(dir, fileNameOf(stored));
  }

  /// Matches an attachment filename in either reference form, since both end
  /// in `media/<name>`. Filenames are `<prefix>_<timestamp><ext>`, so the
  /// character class covers them.
  static final RegExp _reference = RegExp(r'media/([A-Za-z0-9._\-]+)');

  /// Every attachment a note's content refers to.
  ///
  /// Deliberately a loose scan of the raw string rather than a parse of the
  /// Quill delta: the delta stores each embed as JSON inside a JSON string, and
  /// a parser that has to survive both that and plain-markdown notes is more
  /// ways to be wrong than this is. A false positive costs nothing -- a
  /// filename that matches no local file is skipped on upload, and one the
  /// server does not hold is skipped on download.
  static Set<String> referencedIn(String content) {
    if (content.isEmpty) return const {};
    return {
      for (final match in _reference.allMatches(content))
        if (match.group(1) != null && match.group(1)!.isNotEmpty) match.group(1)!,
    };
  }
}
