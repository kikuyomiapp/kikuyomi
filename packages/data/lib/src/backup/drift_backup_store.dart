import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import 'library_snapshot_query.dart';
import 'restore_plan_writes.dart';

/// The database's part in backups: the domain's [LibrarySnapshotReader] and [RestoreWriter], over
/// Drift.
///
/// The `backup` package encodes what this reads and plans what this writes. Like `PlaybackStore`, the
/// interfaces live in the domain, so that neither package depends on the other (§2.4).
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
