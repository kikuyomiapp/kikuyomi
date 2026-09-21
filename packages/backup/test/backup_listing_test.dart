import 'dart:io';

import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// The bytes of a backup of [fullLibrary] taken at [time].
List<int> backupAt(DateTime time) => encodeBackup(
  fullLibrary(),
  info: BackupInfo(createdAt: time, appVersion: '1.2.3', deviceId: 'phone'),
);

void main() {
  final monday = DateTime.utc(2026, 9, 14, 9);
  final tuesday = DateTime.utc(2026, 9, 15, 9);
  final wednesday = DateTime.utc(2026, 9, 16, 9);

  late FakeUserFolder folder;

  setUp(() {
    folder = FakeUserFolder(
      files: {
        backupFileName(tuesday): backupAt(tuesday),
        backupFileName(monday): backupAt(monday),
        backupFileName(wednesday): backupAt(wednesday),
      },
    );
  });

  test('lists the backups in a folder newest first, with their dates and book counts', () async {
    final listed = await findBackups(folder);
    expect(
      [for (final backup in listed) backup.takenAt],
      [wednesday, tuesday, monday],
    );
    final newest = listed.first as RestorableBackup;
    expect(newest.fileName, backupFileName(wednesday));
    expect(newest.summary.info.createdAt, wednesday);
    expect(newest.summary.bookCount, 1);
    expect(newest.sizeBytes, backupAt(wednesday).length);
  });

  test('leaves out files that are not backups', () async {
    folder.files
      ..['notes.txt'] = backupAt(monday)
      ..['${backupFileName(monday)}.partial'] = backupAt(monday);
    expect(await findBackups(folder), hasLength(3));
  });

  test('lists a damaged backup with why, and the others as usual', () async {
    final damaged = backupAt(tuesday);
    folder.files[backupFileName(tuesday)] = damaged.sublist(
      0,
      damaged.length - 10,
    );

    final listed = await findBackups(folder);
    expect(listed, hasLength(3));
    final broken = listed[1] as UnrestorableBackup;
    expect(broken.takenAt, tuesday);
    expect(broken.needsNewerApp, isFalse);
    expect(broken.reason, contains('not a complete backup'));
    expect(listed[0], isA<RestorableBackup>());
    expect(listed[2], isA<RestorableBackup>());
  });

  test('lists a backup from a newer app as needing one', () async {
    folder.files[backupFileName(monday)] = gzip.encode([
      ...gzip.decode(backupAt(monday)),
      0x10,
      0x02,
    ]);

    final oldest = (await findBackups(folder)).last as UnrestorableBackup;
    expect(oldest.needsNewerApp, isTrue);
  });

  test('lists nothing in a folder with no backups', () async {
    expect(await findBackups(FakeUserFolder()), isEmpty);
  });

  test('fails when the folder can no longer be reached', () async {
    folder.unreachable = 'the folder no longer exists';
    await expectLater(
      findBackups(folder),
      throwsA(isA<FolderUnavailableException>()),
    );
  });
}
