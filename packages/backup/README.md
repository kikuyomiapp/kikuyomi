# kikuyomi_backup

The backup format, reading and writing backup files, and the restore planner, and the automatic
backups built on them: naming backup files, which ones to keep, writing one to the folder the user
chose, listing a folder's backups, and when to back up. Pure Dart: it depends only on
`kikuyomi_domain`, plus `protobuf` and `fixnum` for the format itself. The folder and the settings
it works with are domain interfaces, implemented by the platform adapters.

## Automatic backups

- **Names.** `kikuyomi-backup-2026-09-14T15-30-12-345Z.kybackup`: the time taken, in UTC to the
  millisecond, so names sort by time. Only files named so are ever listed, restored from or deleted.
- **Retention.** The newest three backups, and the newest from each of the past seven local calendar
  days, are kept; other backups are deleted after each successful write.
- **When.** A backup is due once anything it carries changes. It runs when changes have settled for
  three minutes, but no later than fifteen minutes after the first unsaved change, and when the app
  goes to the background or closes. With nothing changed, nothing is written. One runs at a time.

The values it works with, library snapshots and restore plans, and the interfaces through which it
reads and restores the library, live in `kikuyomi_domain` under `lib/src/backup/`. The data package
implements those interfaces over the database, so neither package depends on the other (§2.4 of the
architecture), the same arrangement as `PlaybackStore`.

The format is gzipped protobuf, as [ADR-0008](../../docs/adr/0008-gzipped-protobuf-backups.md)
decided. Backups exist so that an Android uninstall or an iOS re-sign loses nothing, which means a
backup has to restore cleanly into a build that is newer *or older* than the one that wrote it.

## The format

- The schema is [`proto/backup.proto`](proto/backup.proto). Its header comment lists the rules for
  changing it, and what is deliberately left out of a backup, and why.
- A backup file is a single gzip member holding one serialized `Backup` message.
- `format_version` is the schema version the writer implemented. `min_reader_version` is the oldest
  format version that can still restore the backup correctly. Additive changes raise the first and
  leave the second alone, so older builds keep reading newer backups. A reader refuses a backup
  whose `min_reader_version` is newer than it knows.
- Reading is strict at the boundary. A file that is not gzip, is damaged, is cut short, or is not a
  backup is refused whole. `dart:io` does not notice a gzip file cut short, so the codec checks the
  gzip trailer itself. Individual items that cannot be restored faithfully, such as a bookmark in a
  chapter the backup lacks, are left out and listed rather than failing the whole restore.

## Regenerating the Dart code

The code generated from the schema lives in `lib/src/generated/` and is committed, because CI has no
`protoc`. Regenerate it whenever `proto/backup.proto` changes, and commit it with the change.

The tool versions are pinned. A different `protoc_plugin` produces a different, noisy diff, and
`protoc_plugin` 25.1.0 generates code for the `protobuf` ^6.1.0 runtime in `pubspec.yaml`. Bump them
together, deliberately.

One-time setup, outside the repository:

1. Download `protoc-36.1-win64.zip` from the official releases page,
   <https://github.com/protocolbuffers/protobuf/releases/tag/v36.1>, and unzip it, for example to
   `%LOCALAPPDATA%\kikuyomi-tools\protoc-36.1`.
2. With the Flutter SDK's `bin` folder on `PATH`, install the Dart generator:

   ```powershell
   dart pub global activate protoc_plugin 25.1.0
   ```

Then, from the repository root in PowerShell, again with the Flutter SDK's `bin` folder on `PATH`
(the generator is a script that runs `dart`):

```powershell
& "$env:LOCALAPPDATA\kikuyomi-tools\protoc-36.1\bin\protoc.exe" "--plugin=protoc-gen-dart=$env:LOCALAPPDATA\Pub\Cache\bin\protoc-gen-dart.bat" --dart_out=packages\backup\lib\src\generated --proto_path=packages\backup\proto packages\backup\proto\backup.proto
dart format packages\backup
```

The `dart format` step matters: the generator's own formatting differs from the SDK's, and CI checks
formatting.

## Adding a field

1. Give it the next unused field number. Never reuse or renumber one, and when removing a field,
   move its number and name into a `reserved` statement.
2. Make sure its default reads correctly for every backup written before it existed.
3. Regenerate, as above.
4. Raise `backupFormatVersion` in `lib/src/codec.dart`. Leave `backupMinReaderVersion` alone unless
   older readers would restore the new backups incorrectly, which deserves an ADR of its own.
5. Add it to the snapshot types in `packages/domain/lib/src/backup/library_snapshot.dart`, write and
   read it in `lib/src/codec.dart`, and set it in `fullLibrary()` in `test/fixtures.dart`. The test `sets every field of the format from a fully populated library`
   fails until both are done.
6. Carry it through the database reader and writer in `packages/data/lib/src/backup/`, whose
   round-trip test compares every column.
