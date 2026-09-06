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

import 'media_sync_types.dart';
import 'sync_api_client.dart';

/// Browser build: nothing to reconcile.
///
/// There is no local attachment directory to compare against, so there is
/// nothing to upload and nothing worth pre-fetching. Images are resolved
/// straight from the server when a note displays one.
class MediaSync {
  const MediaSync();

  Future<MediaSyncResult> run(SyncApiClient client) async =>
      const MediaSyncResult();
}
