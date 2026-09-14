/// Protobuf schema, export and import, restore planner.
///
/// Field numbers are append-only, so a backup taken by a newer build stays readable by an older
/// one and vice versa.
///
/// The library snapshots and restore plans it works with, and the interfaces through which it reads
/// and restores the library, are domain types, so that the data package can implement them without
/// depending on this package (§2.4).
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/backup_and_restore.dart';
export 'src/codec.dart';
export 'src/restore_planner.dart';
