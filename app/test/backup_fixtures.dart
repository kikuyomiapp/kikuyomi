// Backups, as the backup screens are given them, for their tests.

import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// 3:30 in the afternoon, local time, on a Monday.
final monday = DateTime(2026, 9, 14, 15, 30);

/// [monday] as the backup screens show it.
const mondayShown = 'Mon, Sep 14, 2026 at 3:30 PM';

/// A backup this build can restore, taken at [takenAt], holding [books] books.
RestorableBackup restorable(DateTime takenAt, {int books = 12}) =>
    RestorableBackup(
      fileName: backupFileName(takenAt),
      takenAt: takenAt,
      summary: BackupSummary(
        formatVersion: backupFormatVersion,
        minReaderVersion: backupMinReaderVersion,
        info: BackupInfo(
          createdAt: takenAt,
          appVersion: '1.0.0+1',
          deviceId: 'phone',
        ),
        bookCount: books,
      ),
    );

/// A backup that cannot be restored, for [problem].
UnrestorableBackup unrestorable(DateTime takenAt, Exception problem) =>
    UnrestorableBackup(
      fileName: backupFileName(takenAt),
      takenAt: takenAt,
      problem: problem,
    );

/// A book, in the library or not.
BookSnapshot book(String key, {bool inLibrary = true}) => BookSnapshot(
  sourceId: 1,
  key: key,
  details: BookDetailsSnapshot(title: key),
  inLibrary: inLibrary,
  createdAt: DateTime.utc(2026, 9, 1),
  updatedAt: DateTime.utc(2026, 9, 1),
);

/// A library of [books], from the built-in local source.
LibrarySnapshot libraryOf(List<BookSnapshot> books) => LibrarySnapshot(
  sources: const [
    SourceSnapshot(id: 1, key: 'local', name: 'Local files', lang: 'und'),
  ],
  books: books,
);

/// A restore that added [added] and merged [merged], leaving out [skipped].
RestoreReport reportOf({
  List<BookSnapshot> added = const [],
  int merged = 0,
  List<String> skipped = const [],
}) => RestoreReport(
  backup: DecodedBackup(
    formatVersion: backupFormatVersion,
    info: BackupInfo(createdAt: monday, appVersion: '1.0.0+1', deviceId: 'x'),
    library: const LibrarySnapshot(),
    skipped: skipped,
  ),
  plan: RestorePlan(
    newBooks: added,
    mergedBooks: [
      for (var i = 0; i < merged; i++)
        BookMerge(
          sourceId: 1,
          key: 'merged $i',
          updatedAt: DateTime.utc(2026, 9, 1),
          addToLibrary: true,
        ),
    ],
  ),
);

/// A library that records the restores applied to it, standing in for the database.
final class RecordingLibrary implements LibrarySnapshotReader, RestoreWriter {
  RecordingLibrary([this.snapshot = const LibrarySnapshot()]);

  LibrarySnapshot snapshot;
  final applied = <RestorePlan>[];

  /// When set, restoring fails with it.
  Object? failure;

  @override
  Future<LibrarySnapshot> readLibrary() async => snapshot;

  @override
  Future<RestorePlan> restore(
    RestorePlan Function(LibrarySnapshot current) plan,
  ) async {
    final failure = this.failure;
    if (failure != null) throw failure;
    final planned = plan(snapshot);
    applied.add(planned);
    return planned;
  }
}
