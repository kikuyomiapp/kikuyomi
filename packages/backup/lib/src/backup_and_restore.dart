/// Making a backup of the library, and restoring one into it.
///
/// These tie the codec, the planner and the library interfaces together. Writing backups to the
/// folder the user chose is `backup_service.dart`'s, and deciding when is `backup_scheduler.dart`'s;
/// how a folder is chosen and kept belongs to the platform adapters (§5.1).
library;

import 'dart:typed_data';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'codec.dart';
import 'restore_planner.dart';

/// The part of [library] that a backup keeps.
///
/// - Every book in the library, and every book outside it that carries user data. Progress on a book
///   the user never added to the library is still progress.
/// - Only the sources those books refer to. A source row exists so that books have somewhere to
///   point.
/// - Every category, empty ones included, since the user made them. A backup identifies categories
///   by name, so where two share one, only the first listed is kept.
///
/// Left out are books outside the library with no user data. They are details cached while browsing,
/// and opening the book fetches them again.
LibrarySnapshot selectForBackup(LibrarySnapshot library) {
  final books = [
    for (final book in library.books)
      if (book.inLibrary || book.carriesUserData) book,
  ];
  final sourceIds = {for (final book in books) book.sourceId};
  final names = <String>{};
  return LibrarySnapshot(
    sources: List.unmodifiable([
      for (final source in library.sources)
        if (sourceIds.contains(source.id)) source,
    ]),
    categories: List.unmodifiable([
      for (final category in library.categories)
        if (names.add(category.name)) category,
    ]),
    books: List.unmodifiable(books),
  );
}

/// Reads [library] and returns the bytes of a backup file of it.
Future<Uint8List> createBackup(
  LibrarySnapshotReader library, {
  required Clock clock,
  required String appVersion,
  required String deviceId,
}) async {
  // Taken before reading, so that the time never claims more than the backup holds.
  final createdAt = clock.now();
  final snapshot = await library.readLibrary();
  return encodeBackup(
    selectForBackup(snapshot),
    info: BackupInfo(
      createdAt: createdAt,
      appVersion: appVersion,
      deviceId: deviceId,
    ),
  );
}

/// What a restore did.
final class RestoreReport {
  const RestoreReport({required this.backup, required this.plan});

  /// The backup restored from: who wrote it, when, and what had to be left out of it.
  final DecodedBackup backup;

  /// What the restore changed. Empty when the library already held everything in the backup.
  final RestorePlan plan;
}

/// Restores the backup file [bytes] into [library].
///
/// The whole file is read before the library is touched, so when it cannot be restored from, the
/// [BackupException] leaves the library exactly as it was. Planning and applying then happen together,
/// inside the writer's transaction.
Future<RestoreReport> restoreBackup(
  List<int> bytes, {
  required RestoreWriter library,
}) async {
  final backup = decodeBackup(bytes);
  final plan = await library.restore(
    (current) => planRestore(backup: backup.library, current: current),
  );
  return RestoreReport(backup: backup, plan: plan);
}
