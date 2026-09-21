import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/restore_session.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';

import 'backup_fixtures.dart';

void main() {
  final takenAt = DateTime.utc(2026, 9, 14, 12);

  late FakeUserFolders folders;
  late FakeUserFolder folder;
  late InMemorySettingsStore settings;
  late RecordingLibrary library;
  late BackupService backups;
  late int settled;
  late RestoreSession session;

  setUp(() {
    folders = FakeUserFolders();
    folder = FakeUserFolder(
      files: {
        backupFileName(takenAt): encodeBackup(
          libraryOf([book('a'), book('b')]),
          info: BackupInfo(
            createdAt: takenAt,
            appVersion: '1.0.0+1',
            deviceId: 'phone',
          ),
        ),
      },
    );
    settings = InMemorySettingsStore();
    library = RecordingLibrary();
    backups = BackupService(
      library: library,
      restorer: library,
      folders: folders,
      settings: settings,
      clock: FakeClock(takenAt),
      appVersion: '1.0.0+1',
      deviceId: 'phone',
    );
    settled = 0;
    session = RestoreSession(
      backups: backups,
      afterRestore: () async => settled++,
    );
    addTearDown(session.dispose);
  });

  test(
    'with no backup folder chosen, asks for the folder backups are in',
    () async {
      await session.start();
      expect(session.step, isA<RestoreChoosingFolder>());
    },
  );

  test(
    'lists the backups in the folder chosen, and keeps it for backups',
    () async {
      await session.start();
      folders.nextChoice = folder;
      await session.chooseFolder();

      final step = session.step as RestoreChoosingBackup;
      expect(step.folderName, 'Backups');
      expect((step.backups.single as RestorableBackup).summary.bookCount, 2);
      expect(settings.read(AppSettings.backupFolder), folder.handle);
    },
  );

  test('stays where it was when choosing a folder is cancelled', () async {
    await session.start();
    await session.chooseFolder();
    expect(session.step, isA<RestoreChoosingFolder>());
  });

  test('starts in the backup folder already chosen', () async {
    folders.add(folder);
    await settings.write(AppSettings.backupFolder, folder.handle);

    await session.start();
    expect(session.step, isA<RestoreChoosingBackup>());
  });

  test(
    'asks for another folder when the one chosen can no longer be reached',
    () async {
      folders.add(folder);
      await settings.write(AppSettings.backupFolder, folder.handle);
      folder.unreachable = 'the folder no longer exists';

      await session.start();
      final step = session.step as RestoreChoosingFolder;
      expect(step.problem, contains('the folder no longer exists'));
    },
  );

  group('restoring the backup chosen', () {
    setUp(() async {
      folders.add(folder);
      await settings.write(AppSettings.backupFolder, folder.handle);
      await session.start();
    });

    RestorableBackup listed() =>
        (session.step as RestoreChoosingBackup).backups.single
            as RestorableBackup;

    test('reports what it did, and settles the library afterwards', () async {
      await session.restore(listed());

      final done = session.step as RestoreDone;
      expect([for (final b in done.report.plan.newBooks) b.key], ['a', 'b']);
      expect(library.applied, hasLength(1));
      expect(settled, 1);
    });

    test('says why it failed, and goes back to the list', () async {
      library.failure = StateError('the database is locked');
      final backup = listed();
      await session.restore(backup);

      final failed = session.step as RestoreFailed;
      expect(failed.reason, contains('the database is locked'));
      expect(settled, 0);

      session.backToBackups();
      expect(session.step, isA<RestoreChoosingBackup>());
    });

    test('refuses a backup damaged since it was listed', () async {
      final backup = listed();
      final name = backup.fileName;
      folder.files[name] = folder.files[name]!.sublist(0, 30);

      await session.restore(backup);
      expect(session.step, isA<RestoreFailed>());
      expect(library.applied, isEmpty);
    });
  });

  test('tells its listeners of each step', () async {
    var told = 0;
    session.addListener(() => told++);
    folders.add(folder);
    await settings.write(AppSettings.backupFolder, folder.handle);

    await session.start();
    // Looking, then the list.
    expect(told, 2);
  });
}
