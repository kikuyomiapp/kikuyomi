import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/backup_settings_view.dart';

import 'backup_fixtures.dart';

/// The Backup section, recording the buttons pressed in [pressed].
Widget section({
  BackupFolderState folder = const BackupFolderReady('Backups'),
  DateTime? lastBackupAt,
  String? lastProblem,
  bool backingUp = false,
  bool libraryIsEmpty = false,
  List<String>? pressed,
}) => MaterialApp(
  home: Scaffold(
    body: BackupSettingsView(
      folder: folder,
      lastBackupAt: lastBackupAt,
      lastProblem: lastProblem,
      backingUp: backingUp,
      libraryIsEmpty: libraryIsEmpty,
      onChooseFolder: () => pressed?.add('choose folder'),
      onBackUpNow: () => pressed?.add('back up now'),
      onRestore: () => pressed?.add('restore'),
    ),
  ),
);

/// The button labelled [label], of whatever kind.
ButtonStyleButton button(WidgetTester tester, String label) =>
    tester.widget<ButtonStyleButton>(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          )
          .first,
    );

void main() {
  testWidgets('shows the folder and when the last backup was written', (
    tester,
  ) async {
    await tester.pumpWidget(section(lastBackupAt: monday));
    expect(find.text('Backups'), findsOneWidget);
    expect(find.text('Change folder'), findsOneWidget);
    expect(find.text(mondayShown), findsOneWidget);
  });

  testWidgets('says Never before the first backup', (tester) async {
    await tester.pumpWidget(section());
    expect(find.text('Never'), findsOneWidget);
  });

  testWidgets('backs up now, and changes the folder, when asked', (
    tester,
  ) async {
    final pressed = <String>[];
    await tester.pumpWidget(section(pressed: pressed));
    await tester.tap(find.text('Back up now'));
    await tester.tap(find.text('Change folder'));
    expect(pressed, ['back up now', 'choose folder']);
  });

  testWidgets('offers to choose a folder before one is chosen, and cannot '
      'back up yet', (tester) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      section(folder: const NoBackupFolder(), pressed: pressed),
    );
    expect(find.text('Not chosen yet'), findsOneWidget);
    expect(button(tester, 'Back up now').onPressed, isNull);

    await tester.tap(find.text('Choose folder'));
    expect(pressed, ['choose folder']);
  });

  testWidgets('can back up while the folder is being checked', (tester) async {
    await tester.pumpWidget(
      section(folder: const BackupFolderChecking('Backups')),
    );
    expect(find.text('Backups'), findsOneWidget);
    expect(button(tester, 'Back up now').onPressed, isNotNull);
  });

  testWidgets(
    'explains a folder that can no longer be reached, and offers to choose it again',
    (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        section(
          folder: const BackupFolderLost(
            'Backups',
            'the folder no longer exists',
          ),
          lastProblem: 'The backup folder can no longer be reached',
          pressed: pressed,
        ),
      );
      expect(
        find.textContaining(
          'can no longer be reached: the folder no longer exists',
        ),
        findsOneWidget,
      );
      expect(button(tester, 'Back up now').onPressed, isNull);

      await tester.tap(find.text('Choose it again'));
      expect(pressed, ['choose folder']);
    },
  );

  testWidgets('shows what went wrong with the last backup', (tester) async {
    await tester.pumpWidget(
      section(lastProblem: 'Could not back up: the disk is full'),
    );
    expect(find.text('Could not back up: the disk is full'), findsOneWidget);
  });

  testWidgets('shows a backup under way, and takes no second one', (
    tester,
  ) async {
    await tester.pumpWidget(section(backingUp: true));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(button(tester, 'Back up now').onPressed, isNull);
  });

  group('restoring', () {
    testWidgets(
      'into a library in use asks first, saying a restore never removes anything',
      (tester) async {
        final pressed = <String>[];
        await tester.pumpWidget(section(pressed: pressed));

        await tester.tap(find.text('Restore from a backup'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'A restore never removes anything from your library, and keeps '
            'whichever progress is newer.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(pressed, isEmpty);

        await tester.tap(find.text('Restore from a backup'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(pressed, ['restore']);
      },
    );

    testWidgets('into an empty library goes ahead without asking', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(section(libraryIsEmpty: true, pressed: pressed));
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(pressed, ['restore']);
    });
  });

  testWidgets('says when this device cannot keep a backup folder yet', (
    tester,
  ) async {
    await tester.pumpWidget(section(folder: const BackupFoldersUnsupported()));
    expect(find.text('Not available on this device yet'), findsOneWidget);
    expect(find.text('Back up now'), findsNothing);
    expect(find.text('Restore from a backup'), findsNothing);
  });
}
