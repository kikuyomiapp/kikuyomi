import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/backup_text.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';

import 'backup_fixtures.dart';

void main() {
  test('counts books in words', () {
    expect(countBooks(0), '0 books');
    expect(countBooks(1), '1 book');
    expect(countBooks(12), '12 books');
  });

  testWidgets('shows when a backup was taken with its date, year and time', (
    tester,
  ) async {
    late String shown;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            shown = formatBackupTime(context, monday.toUtc());
            return const SizedBox();
          },
        ),
      ),
    );
    expect(shown, mondayShown);
  });

  test('says how a backup went', () {
    expect(
      describeBackupOutcome(
        BackupWritten(fileName: 'b', takenAt: DateTime.utc(2026)),
      ),
      'Backed up',
    );
    expect(
      describeBackupOutcome(const BackupNotConfigured()),
      'Choose a backup folder first',
    );
    expect(
      describeBackupOutcome(
        const BackupFolderUnreachable('the folder no longer exists'),
      ),
      'The backup folder can no longer be reached: the folder no longer exists',
    );
    expect(
      describeBackupOutcome(
        BackupFailed(StateError('the disk is full'), StackTrace.empty),
      ),
      startsWith('Could not back up: '),
    );
  });

  group('says what a restore did', () {
    test('counting the books it added to the library', () {
      expect(
        describeRestore(
          reportOf(
            added: [book('a'), book('b'), book('outside', inLibrary: false)],
          ),
        ),
        ['Added 2 books to your library.'],
      );
    });

    test('and the books it brought up to date', () {
      expect(describeRestore(reportOf(added: [book('a')], merged: 3)), [
        'Added 1 book to your library.',
        'Brought 3 books up to date.',
      ]);
    });

    test('or that there was nothing to restore', () {
      expect(describeRestore(reportOf()), [
        'Your library already had everything in this backup.',
      ]);
    });

    test('even when it only brought back books outside the library', () {
      expect(describeRestore(reportOf(added: [book('a', inLibrary: false)])), [
        'Restored the backup.',
      ]);
    });
  });
}
