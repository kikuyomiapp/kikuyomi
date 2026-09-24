import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'converters.dart';
import 'database.steps.dart';
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
    Extensions,
    ExtensionPreferences,
  ],
)
class KikuyomiDatabase extends _$KikuyomiDatabase {
  /// The caller supplies the executor: a file-backed database in the app, an in-memory one in tests.
  /// Opening a file here would tie this pure-Dart package to where the app keeps its data.
  KikuyomiDatabase(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    // One step per version, each written against that version's own tables rather than against
    // today's, which is drift's `stepByStep`. A migration that said `createTable(extensions)` would
    // create whatever shape that table has when the app is built, so a library upgraded from version
    // 1 two versions from now would get a version-4 table in its version-2 step. `database.steps.dart`
    // is generated from the schema snapshots by `dart run drift_dev make-migrations`.
    onUpgrade: stepByStep(
      // Version 2 only adds tables: what extensions are installed, and what they have stored.
      // Nothing that version 1 wrote is moved or rewritten.
      from1To2: (m, schema) async {
        await m.createTable(schema.extensions);
        await m.createTable(schema.extensionPreferences);
      },
    ),
    beforeOpen: (details) async {
      // SQLite leaves foreign keys off unless each connection asks for them, and every cascade and
      // restriction in the schema means nothing without this.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
