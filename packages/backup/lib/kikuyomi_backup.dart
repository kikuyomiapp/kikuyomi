/// Protobuf schema, export and import, restore planner.
///
/// Field numbers are append-only, so a backup taken by a newer build stays readable by an older
/// one and vice versa.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/backup_and_restore.dart';
export 'src/codec.dart';
export 'src/library_store.dart';
export 'src/restore_plan.dart';
export 'src/restore_planner.dart';
export 'src/snapshot.dart';
