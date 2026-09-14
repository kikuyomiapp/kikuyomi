/// The library, as backup and restore need it, behind interfaces.
///
/// §2.4 lets this package depend on the domain alone, so it cannot reach the database. It says here
/// what it needs instead, and the data package implements it over Drift, the same way the domain's
/// `PlaybackStore` joins playback to the database without either knowing the other.
library;

import 'restore_plan.dart';
import 'snapshot.dart';

/// Reads the library as it is now.
abstract interface class LibrarySnapshotReader {
  /// Everything stored: every source and category, and every book, whether in the library or not,
  /// with everything that hangs off it.
  ///
  /// Books outside the library are included because a restore has to match against them too. Which
  /// books a backup keeps is decided afterwards, by `selectForBackup`.
  ///
  /// Lists come in a stable order that depends on identities, never on database ids, so that two
  /// databases holding the same library read identically: sources by id, categories by sort order
  /// and then name, books by source and then key, chapters by source index and then key, and
  /// everything else by key or by time.
  Future<LibrarySnapshot> readLibrary();
}

/// Applies restores to the library.
abstract interface class RestoreWriter {
  /// Reads the library, asks [plan] what to change given what it holds now, and applies the plan it
  /// returns, all in one transaction. Returns the plan applied.
  ///
  /// One transaction, because the plan is worked out by comparing the backup with the library.
  /// Progress saved by playback between a separate read and write could otherwise be overwritten by
  /// older progress from the backup, which the plan chose only because it had not seen the newer.
  Future<RestorePlan> restore(
    RestorePlan Function(LibrarySnapshot current) plan,
  );
}
