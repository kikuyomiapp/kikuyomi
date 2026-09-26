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

/// Where a local path stored in the database is on this device: [stored] itself when it is absolute,
/// and otherwise [stored] under [mediaRoot], as [LocalMediaResolver] describes. The same for a
/// folder's path as for a file's.
String resolveLocalPath(String stored, {required Directory mediaRoot}) =>
    File(stored).isAbsolute ? stored : '${mediaRoot.path}/$stored';

/// §6.3's resolver for files already on this device: imported books and downloads alike.
///
/// A stored `local_path` is absolute for a file that stays where the user keeps it, and otherwise
/// relative to one of two roots. App storage is never referred to by an absolute path because its
/// location is not stable: on iOS an app's container can move when the app is updated or reinstalled,
/// which would break every absolute path into it.
///
/// **Which root is decided by `downloaded_at`.** A file the download queue put here is relative to
/// [downloadRoot] and a file the listener imported is relative to [mediaRoot], and the two are not the
/// same folder — on iOS they are not even on the same branch, since imports live in Documents so the
/// Files app shows them while downloads stay app-private. `downloaded_at` is written in the same
/// transaction as the path it belongs to and by nothing else, so the pair of columns says both where
/// the file is and what it is relative to, and no third column is needed to tell them apart.
///
/// There is nothing to refresh for a local file, so `refresh` is ignored. A stream error on a local
/// file means the file itself is unreadable, which resolving it again cannot fix.
final class LocalMediaResolver implements MediaResolver {
  LocalMediaResolver(
    this._db, {
    required this.mediaRoot,
    required this.downloadRoot,
  });

  final KikuyomiDatabase _db;

  /// What an imported file's relative path is relative to.
  final Directory mediaRoot;

  /// What a downloaded file's relative path is relative to (§5.2).
  ///
  /// Required rather than defaulted to [mediaRoot]: a resolver that cannot find the files the download
  /// queue kept is one that makes a downloaded book unplayable, and it would do it silently.
  final Directory downloadRoot;

  /// Every file this resolver answers for is on the device, so nothing it can resolve costs
  /// anything to resolve. One that is missing is not in hand, and says so when it is played.
  @override
  Future<ResolvedMedia?> resolveIfOnHand(int fileId) async {
    try {
      return await resolve(fileId);
    } on MediaUnavailableException {
      return null;
    }
  }

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
    final file = File(
      resolveLocalPath(
        path,
        mediaRoot: row.downloadedAt == null ? mediaRoot : downloadRoot,
      ),
    );
    if (!await file.exists()) {
      throw MediaUnavailableException(
        'file "${row.fileKey}" is missing from ${file.path}',
      );
    }
    return ResolvedMedia(uri: Uri.file(file.path));
  }
}
