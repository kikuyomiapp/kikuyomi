import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/restore_session.dart';
import 'package:kikuyomi/src/setup_screen.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';

import 'backup_fixtures.dart';

void main() {
  final takenAt = DateTime.utc(2026, 9, 14, 12);

  late FakeUserFolders folders;
  late InMemorySettingsStore settings;
  late RecordingLibrary library;
  late BackupService backups;
  late int settled;
  late int finished;

  /// A folder holding one backup, of a library of two books.
  FakeUserFolder withBackup() => FakeUserFolder(
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

  Widget setup() => MaterialApp(
    home: Scaffold(
      body: SetupFlow(
        backups: backups,
        settings: settings,
        newSession: () => RestoreSession(
          backups: backups,
          afterRestore: () async => settled++,
        ),
        onFinished: () => finished++,
      ),
    ),
  );

  setUp(() {
    folders = FakeUserFolders();
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
    finished = 0;
  });

  testWidgets('offers to choose a folder, to restore, or to skip', (
    tester,
  ) async {
    await tester.pumpWidget(setup());
    expect(find.text('Keep your library safe'), findsOneWidget);
    expect(find.text('Choose a backup folder'), findsOneWidget);
    expect(find.text('Restore from a backup'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
  });

  testWidgets('skipping is remembered, and finishes', (tester) async {
    await tester.pumpWidget(setup());
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(settings.read(AppSettings.backupSetup), BackupSetup.skipped);
    expect(finished, 1);
  });

  testWidgets('choosing an empty folder keeps it for backups, and finishes', (
    tester,
  ) async {
    final folder = folders.nextChoice = FakeUserFolder();
    await tester.pumpWidget(setup());
    await tester.tap(find.text('Choose a backup folder'));
    await tester.pumpAndSettle();

    expect(settings.read(AppSettings.backupFolder), folder.handle);
    expect(settings.read(AppSettings.backupSetup), BackupSetup.completed);
    expect(finished, 1);
  });

  testWidgets(
    'choosing a folder that holds backups offers to restore one first',
    (tester) async {
      folders.nextChoice = withBackup();
      await tester.pumpWidget(setup());
      await tester.tap(find.text('Choose a backup folder'));
      await tester.pumpAndSettle();

      expect(find.text('Backups in Backups'), findsOneWidget);
      expect(finished, 0);

      await tester.tap(find.text('Start without restoring'));
      await tester.pumpAndSettle();
      expect(settings.read(AppSettings.backupSetup), BackupSetup.completed);
      expect(finished, 1);
      expect(library.applied, isEmpty);
    },
  );

  testWidgets(
    'restoring lists the backups in the folder chosen, restores the one '
    'picked, and finishes when done',
    (tester) async {
      final folder = folders.nextChoice = withBackup();
      await tester.pumpWidget(setup());
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();

      expect(find.text('2 books'), findsOneWidget);
      await tester.tap(find.text('2 books'));
      await tester.pumpAndSettle();

      expect(find.text('Added 2 books to your library.'), findsOneWidget);
      expect(library.applied, hasLength(1));
      expect(settled, 1);
      expect(finished, 0);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(settings.read(AppSettings.backupFolder), folder.handle);
      expect(settings.read(AppSettings.backupSetup), BackupSetup.completed);
      expect(finished, 1);
    },
  );

  testWidgets(
    'going on without a folder to restore from returns to the choices',
    (tester) async {
      await tester.pumpWidget(setup());
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      expect(find.text('Where are your backups?'), findsOneWidget);

      await tester.tap(find.text('Start without restoring'));
      await tester.pumpAndSettle();
      expect(find.text('Keep your library safe'), findsOneWidget);
      expect(finished, 0);
    },
  );

  testWidgets('says why a folder cannot be chosen', (tester) async {
    folders.canChoose = false;
    await tester.pumpWidget(setup());
    await tester.tap(find.text('Choose a backup folder'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not use that folder: not supported on this device'),
      findsOneWidget,
    );
    expect(finished, 0);
  });
}
