import 'package:kikuyomi_backup/kikuyomi_backup.dart';

import '../database/database.dart';
import 'library_snapshot_query.dart';
import 'restore_plan_writes.dart';

/// The database's part in backups: the `backup` package's [LibrarySnapshotReader] and
/// [RestoreWriter], over Drift.
///
/// Everything else about backups is pure Dart in that package, which §2.4 does not let depend on
/// this one. It states what it needs of the library as interfaces, and this is their implementation.
final class DriftBackupStore implements LibrarySnapshotReader, RestoreWriter {
  DriftBackupStore(this._db);

  final KikuyomiDatabase _db;

  /// Read in one transaction, so that every table is read at the same moment and a backup never
  /// pairs progress with a chapter list from a moment later.
  @override
  Future<LibrarySnapshot> readLibrary() =>
      _db.transaction(() => readLibrarySnapshot(_db));

  /// Reads, plans and writes in one transaction, as [RestoreWriter.restore] requires. If any write
  /// fails, the transaction rolls back and the library is left as it was.
  @override
  Future<RestorePlan> restore(
    RestorePlan Function(LibrarySnapshot current) plan,
  ) => _db.transaction(() async {
    final planned = plan(await readLibrarySnapshot(_db));
    await applyRestorePlan(_db, planned);
    return planned;
  });
}
