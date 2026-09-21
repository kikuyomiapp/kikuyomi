import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

import 'fixtures.dart';
import 'in_memory_library.dart';

/// A library that cannot be read.
final class BrokenLibrary implements LibrarySnapshotReader {
  @override
  Future<LibrarySnapshot> readLibrary() async =>
      throw StateError('the database is locked');
}

void main() {
  late FakeClock clock;
  late InMemorySettingsStore settings;
  late FakeUserFolders folders;
  late FakeUserFolder folder;
  late InMemoryLibrary library;
  late BackupService service;

  BackupService serviceOf({
    LibrarySnapshotReader? reader,
    RestoreWriter? restorer,
  }) => BackupService(
    library: reader ?? library,
    restorer: restorer ?? library,
    folders: folders,
    settings: settings,
    clock: clock,
    appVersion: '1.2.3',
    deviceId: 'phone',
    // Calendar days in UTC, whatever the machine running the tests.
    localTime: (instant) => instant.toUtc(),
  );

  /// Chooses [folder] as the backup folder, as the user would.
  Future<void> chooseFolder() async {
    folders.nextChoice = folder;
    await service.chooseFolder();
  }

  /// A backup taken [ago] before now, as a name in the folder.
  String backupFrom(Duration ago) {
    final name = backupFileName(clock.now().subtract(ago));
    folder.files[name] = encodeBackup(fullLibrary(), info: info);
    return name;
  }

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 9, 14, 12));
    settings = InMemorySettingsStore();
    folders = FakeUserFolders();
    folder = FakeUserFolder();
    library = InMemoryLibrary(fullLibrary());
    service = serviceOf();
  });

  test('writes nothing before a folder is chosen, and says so', () async {
    expect(service.folder, isNull);
    expect(await service.backUp(), isA<BackupNotConfigured>());
    expect(settings.read(AppSettings.lastBackupAt), isNull);
  });

  group('choosing a folder', () {
    test('keeps it for backups from then on', () async {
      await chooseFolder();
      expect(settings.read(AppSettings.backupFolder), folder.handle);
      expect(service.folder?.handle, folder.handle);
    });

    test('keeps the folder there was when cancelled', () async {
      await chooseFolder();
      folders.nextChoice = null;
      expect(await service.chooseFolder(), isNull);
      expect(service.folder?.handle, folder.handle);
    });

    test('tells a watcher about the new folder', () async {
      final seen = <String?>[];
      final subscription = service.watchFolder().listen(
        (folder) => seen.add(folder?.displayName),
      );
      addTearDown(subscription.cancel);
      await chooseFolder();
      await pumpEventQueue();
      expect(seen, [null, 'Backups']);
    });
  });

  group('once a folder is chosen', () {
    setUp(chooseFolder);

    test('writes a backup of the library named for when it was taken, and records the time', () async {
      final outcome = await service.backUp() as BackupWritten;
      expect(outcome.fileName, backupFileName(clock.now()));
      expect(outcome.takenAt, clock.now());
      expect(outcome.problems, isEmpty);

      final backup = decodeBackup(folder.files[outcome.fileName]!);
      expect(backup.info.createdAt, clock.now());
      expect(backup.info.appVersion, '1.2.3');
      expect(backup.info.deviceId, 'phone');
      expect(backup.library.books.single.key, '/books/a-book');
      expect(settings.read(AppSettings.lastBackupAt), clock.now());
    });

    test('deletes the backups retention no longer keeps, and nothing it did not write', () async {
      final older = [
        for (var hours = 1; hours <= 5; hours++)
          backupFrom(Duration(hours: hours)),
      ];
      final fourDaysAgo = backupFrom(const Duration(days: 4));
      final lastMonth = backupFrom(const Duration(days: 30));
      folder.files['notes.txt'] = [1, 2, 3];

      final outcome = await service.backUp() as BackupWritten;
      expect(
        folder.files.keys,
        unorderedEquals([
          outcome.fileName,
          older[0],
          older[1],
          fourDaysAgo,
          'notes.txt',
        ]),
      );
      expect(
        outcome.removed,
        unorderedEquals([older[2], older[3], older[4], lastMonth]),
      );
    });

    test('removes a backup file left unfinished more than a day ago', () async {
      final abandoned =
          '${backupFileName(clock.now().subtract(const Duration(days: 2)))}'
          '.partial';
      final underWay =
          '${backupFileName(clock.now().subtract(const Duration(hours: 1)))}'
          '.partial';
      folder.files
        ..[abandoned] = [1]
        ..[underWay] = [1];

      final outcome = await service.backUp() as BackupWritten;
      expect(outcome.removed, [abandoned]);
      expect(folder.files.keys, contains(underWay));
    });

    test('reports a folder that can no longer be reached', () async {
      folder.unreachable = 'the folder no longer exists';
      final outcome = await service.backUp();
      expect(
        outcome,
        isA<BackupFolderUnreachable>().having(
          (o) => o.reason,
          'reason',
          'the folder no longer exists',
        ),
      );
      expect(settings.read(AppSettings.lastBackupAt), isNull);
    });

    test('reports a write that failed, and records nothing', () async {
      folder.failNextWrite = const FolderOperationException('the disk is full');
      final outcome = await service.backUp();
      expect(
        outcome,
        isA<BackupFailed>().having(
          (o) => o.reason,
          'reason',
          'the disk is full',
        ),
      );
      expect(folder.files, isEmpty);
      expect(settings.read(AppSettings.lastBackupAt), isNull);
    });

    test('reports a library that could not be read', () async {
      final outcome = await serviceOf(reader: BrokenLibrary()).backUp();
      expect(
        outcome,
        isA<BackupFailed>().having((o) => o.error, 'error', isStateError),
      );
      expect(folder.files, isEmpty);
    });

    test(
      'still reports the backup written when an old one cannot be deleted',
      () async {
        final older = [
          for (var hours = 1; hours <= 3; hours++)
            backupFrom(Duration(hours: hours)),
        ];
        folder.failDeletes.add(older.last);

        final outcome = await service.backUp() as BackupWritten;
        expect(outcome.problems.single, isA<FolderOperationException>());
        expect(folder.files.keys, contains(outcome.fileName));
        expect(settings.read(AppSettings.lastBackupAt), clock.now());
      },
    );
  });

  group('restoring', () {
    late InMemoryLibrary fresh;

    setUp(() async {
      await chooseFolder();
      await service.backUp();
      fresh = InMemoryLibrary();
    });

    test('lists the backups in a folder and restores the one chosen', () async {
      final restoring = serviceOf(restorer: fresh);
      final listed = await restoring.listBackups(folder);
      expect(listed.single, isA<RestorableBackup>());

      final report = await restoring.restore(folder, listed.single);
      expect(report.plan.newBooks.single.key, '/books/a-book');
      expect(fresh.snapshot.books.single.key, '/books/a-book');
    });

    test(
      'leaves the library as it was when a backup cannot be restored',
      () async {
        final name = folder.files.keys.single;
        folder.files[name] = folder.files[name]!.sublist(0, 20);
        final restoring = serviceOf(restorer: fresh);
        final listed = await restoring.listBackups(folder);

        await expectLater(
          restoring.restore(folder, listed.single),
          throwsA(isA<CorruptBackupException>()),
        );
        expect(fresh.applied, isEmpty);
      },
    );
  });
}
