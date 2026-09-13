import 'dart:io';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';

/// A file the resolver could not provide.
final class MediaUnavailableException implements Exception {
  const MediaUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'MediaUnavailableException: $message';
}

/// §6.3's resolver for files already on this device: local books, and later, downloads.
///
/// There is nothing to refresh for a local file, so `refresh` is ignored. A stream error on a local
/// file means the file itself is unreadable, which resolving it again cannot fix.
final class LocalMediaResolver implements MediaResolver {
  LocalMediaResolver(this._db);

  final KikuyomiDatabase _db;

  @override
  Future<ResolvedMedia> resolve(int fileId, {bool refresh = false}) async {
    final row = await (_db.select(
      _db.mediaFiles,
    )..where((f) => f.id.equals(fileId))).getSingleOrNull();
    if (row == null) {
      throw MediaUnavailableException('no media file with id $fileId');
    }
    final path = row.localPath;
    if (path == null) {
      throw MediaUnavailableException(
        'file "${row.fileKey}" is not on this device',
      );
    }
    if (!await File(path).exists()) {
      throw MediaUnavailableException(
        'file "${row.fileKey}" is missing from $path',
      );
    }
    return ResolvedMedia(uri: Uri.file(path));
  }
}
