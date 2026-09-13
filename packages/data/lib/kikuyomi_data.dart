/// Drift schema, migrations, repository implementations, mappers and merge rules.
///
/// The database is the single source of truth. Every schema change ships with a migration and a
/// migration test against the generated schema snapshots.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/merge/chapter_sync.dart';
