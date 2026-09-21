import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/restore_session.dart';
import 'package:kikuyomi/src/restore_view.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';

import 'backup_fixtures.dart';

/// The restore view at [step], recording what was pressed in [pressed].
Widget view(RestoreStep step, {List<String>? pressed, bool optional = false}) =>
    MaterialApp(
      home: Scaffold(
        body: RestoreView(
          step: step,
          onChooseFolder: () => pressed?.add('choose folder'),
          onRestore: (backup) => pressed?.add('restore ${backup.fileName}'),
          onBackToBackups: () => pressed?.add('back'),
          onDone: () => pressed?.add('done'),
          onStartFresh: optional ? () => pressed?.add('start fresh') : null,
        ),
      ),
    );

void main() {
  testWidgets('asks for the folder the backups are in', (tester) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      view(const RestoreChoosingFolder(), pressed: pressed),
    );
    expect(find.text('Where are your backups?'), findsOneWidget);
    expect(find.text('Start without restoring'), findsNothing);

    await tester.tap(find.text('Choose folder'));
    expect(pressed, ['choose folder']);
  });

  testWidgets('says why the folder there was cannot be used', (tester) async {
    await tester.pumpWidget(
      view(const RestoreChoosingFolder(problem: 'the folder no longer exists')),
    );
    expect(find.text('the folder no longer exists'), findsOneWidget);
  });

  testWidgets('shows it is looking in a folder', (tester) async {
    await tester.pumpWidget(view(const RestoreLooking('Backups')));
    expect(find.text('Looking for backups in Backups'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  group('the backups in a folder', () {
    final newest = restorable(monday);
    final older = restorable(
      monday.subtract(const Duration(days: 1)),
      books: 1,
    );

    testWidgets('are listed with their dates and book counts, and restored '
        'when chosen', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        view(
          RestoreChoosingBackup('Backups', [newest, older]),
          pressed: pressed,
        ),
      );
      expect(find.text('Backups in Backups'), findsOneWidget);
      expect(find.text(mondayShown), findsOneWidget);
      expect(find.text('12 books'), findsOneWidget);
      expect(find.text('1 book'), findsOneWidget);

      await tester.tap(find.text(mondayShown));
      expect(pressed, ['restore ${newest.fileName}']);
    });

    testWidgets('say why one cannot be restored, and it cannot be chosen', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        view(
          RestoreChoosingBackup('Backups', [
            unrestorable(
              monday,
              const CorruptBackupException('the file is incomplete'),
            ),
            unrestorable(
              monday.subtract(const Duration(days: 1)),
              UnsupportedBackupVersionException(minReaderVersion: 2),
            ),
          ]),
          pressed: pressed,
        ),
      );
      expect(
        find.text('Cannot be restored: the file is incomplete'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Made by a newer version of Kikuyomi. Update the app to restore it.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text(mondayShown));
      expect(pressed, isEmpty);
    });

    testWidgets('are none, it says so and offers another folder', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        view(const RestoreChoosingBackup('Backups', []), pressed: pressed),
      );
      expect(
        find.text('There are no Kikuyomi backups in this folder.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Choose another folder'));
      expect(pressed, ['choose folder']);
    });

    testWidgets('can be passed over where restoring is optional', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        view(
          RestoreChoosingBackup('Backups', [newest]),
          pressed: pressed,
          optional: true,
        ),
      );
      await tester.tap(find.text('Start without restoring'));
      expect(pressed, ['start fresh']);
    });
  });

  testWidgets('shows the backup being restored', (tester) async {
    await tester.pumpWidget(view(RestoreRestoring(restorable(monday))));
    expect(find.text('Restoring the backup from $mondayShown'), findsOneWidget);
  });

  testWidgets('says what the restore did, and what it left out', (
    tester,
  ) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      view(
        RestoreDone(
          reportOf(
            added: [book('a'), book('b')],
            skipped: [
              'a bookmark of book "a": its chapter is not in the backup',
            ],
          ),
        ),
        pressed: pressed,
      ),
    );
    expect(find.text('Restored'), findsOneWidget);
    expect(find.text('Added 2 books to your library.'), findsOneWidget);
    expect(
      find.text('Left out 1 item that could not be restored:'),
      findsOneWidget,
    );
    expect(
      find.text('• a bookmark of book "a": its chapter is not in the backup'),
      findsOneWidget,
    );

    await tester.tap(find.text('Done'));
    expect(pressed, ['done']);
  });

  testWidgets('says why a restore failed, and goes back to the backups', (
    tester,
  ) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      view(
        RestoreFailed(restorable(monday), 'the file is incomplete'),
        pressed: pressed,
      ),
    );
    expect(find.text('Could not restore the backup'), findsOneWidget);
    expect(find.text('Your library is as it was.'), findsOneWidget);
    expect(find.text('the file is incomplete'), findsOneWidget);

    await tester.tap(find.text('Back to the backups'));
    expect(pressed, ['back']);
  });
}
