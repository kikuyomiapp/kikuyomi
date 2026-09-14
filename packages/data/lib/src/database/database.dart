import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'converters.dart';
import 'tables.dart';

part 'database.g.dart';

/// The app's database. §2.5: the single source of truth, which screens watch rather than copy.
@DriftDatabase(
  tables: [
    Sources,
    Books,
    People,
    BookPeople,
    Chapters,
    MediaFiles,
    ChapterSegments,
    PlaybackStates,
    ListeningSessions,
    Bookmarks,
    Categories,
    BookCategories,
  ],
)
class KikuyomiDatabase extends _$KikuyomiDatabase {
  /// The caller supplies the executor: a file-backed database in the app, an in-memory one in tests.
  /// Opening a file here would tie this pure-Dart package to where the app keeps its data.
  KikuyomiDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    beforeOpen: (details) async {
      // SQLite leaves foreign keys off unless each connection asks for them, and every cascade and
      // restriction in the schema means nothing without this.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
