import 'package:drift/drift.dart';

import '../database/database.dart';

/// The tables a backup carries: every one `DriftBackupStore` reads into a library snapshot.
///
/// A new table is either added here, when the backup format carries it, or left out on purpose, as
/// §5.2's download queue will be. The test that compares this with the schema fails until one or the
/// other is decided.
List<TableInfo<Table, Object?>> backedUpTables(KikuyomiDatabase db) => [
  db.sources,
  db.books,
  db.people,
  db.bookPeople,
  db.chapters,
  db.mediaFiles,
  db.chapterSegments,
  db.playbackStates,
  db.listeningSessions,
  db.bookmarks,
  db.categories,
  db.bookCategories,
];

/// A signal after every committed change to what a backup carries: the library, chapters, progress,
/// listening sessions, bookmarks and categories.
///
/// What the backup scheduler listens to, to know that a backup is due. A signal carries nothing,
/// because the scheduler only needs to know that something changed; the backup reads the library
/// afresh. Progress saves arrive every few seconds during playback, and the scheduler, not this, is
/// what keeps them from causing a backup each.
Stream<void> backedUpChanges(KikuyomiDatabase db) => db
    .tableUpdates(TableUpdateQuery.onAllTables(backedUpTables(db)))
    .map((_) {});
