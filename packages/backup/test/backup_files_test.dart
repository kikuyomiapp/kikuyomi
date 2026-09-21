import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:test/test.dart';

void main() {
  test('names a backup by when it was taken, in UTC to the millisecond', () {
    expect(
      backupFileName(DateTime.utc(2026, 9, 14, 15, 30, 12, 345)),
      'kikuyomi-backup-2026-09-14T15-30-12-345Z.kybackup',
    );
  });

  test('gives a local time the name of the same instant in UTC', () {
    final local = DateTime(2026, 9, 14, 18, 30);
    expect(backupFileName(local), backupFileName(local.toUtc()));
  });

  test('reads back the time a name was made from', () {
    for (final time in [
      DateTime.utc(2026, 9, 14, 15, 30, 12, 345),
      DateTime.utc(2026),
      DateTime.utc(1, 1, 1),
      DateTime.utc(9999, 12, 31, 23, 59, 59, 999),
    ]) {
      expect(backupTimeOf(backupFileName(time)), time);
    }
  });

  test('gives names that sort by time as plain text', () {
    final times = [
      DateTime.utc(2026, 10, 1),
      DateTime.utc(2026, 9, 14, 9),
      DateTime.utc(2025, 12, 31, 23, 59, 59, 999),
      DateTime.utc(2026, 9, 14, 10),
      DateTime.utc(2026, 9, 14, 10, 0, 0, 1),
    ];
    final byName = [for (final time in times) backupFileName(time)]..sort();
    final byTime = [...times]..sort();
    expect(byName, [for (final time in byTime) backupFileName(time)]);
  });

  test('uses no character a platform forbids in a name', () {
    final name = backupFileName(DateTime.utc(2026, 9, 14, 15, 30, 12, 345));
    expect(name, isNot(matches(RegExp(r'[<>:"/\\|?*\s]'))));
  });

  test('does not take other files for backups', () {
    for (final name in [
      'notes.txt',
      'kikuyomi-backup-2026-09-14T15-30-12-345Z.kybackup.partial',
      'kikuyomi-backup-2026-09-14T15-30-12-345Z (1).kybackup',
      'Kikuyomi-backup-2026-09-14T15-30-12-345Z.kybackup',
      'kikuyomi-backup-2026-09-14T15-30-12Z.kybackup',
      'kikuyomi-backup-2026-09-14T15-30-12-345Z.tachibk',
      'kikuyomi-backup-2026-09-31T00-00-00-000Z.kybackup',
      'kikuyomi-backup-2026-13-01T00-00-00-000Z.kybackup',
    ]) {
      expect(backupTimeOf(name), isNull, reason: name);
    }
  });

  group('a backup file never finished', () {
    final taken = DateTime.utc(2026, 9, 14, 15);
    final partial = '${backupFileName(taken)}.partial';

    test('is abandoned once more than a day old', () {
      expect(
        isAbandonedBackupFile(
          partial,
          now: taken.add(const Duration(days: 1, minutes: 1)),
        ),
        isTrue,
      );
    });

    test('may still be being written within a day', () {
      expect(
        isAbandonedBackupFile(
          partial,
          now: taken.add(const Duration(hours: 23)),
        ),
        isFalse,
      );
    });

    test('is only ever one named as a backup', () {
      final later = taken.add(const Duration(days: 30));
      expect(isAbandonedBackupFile('notes.txt.partial', now: later), isFalse);
      expect(isAbandonedBackupFile(backupFileName(taken), now: later), isFalse);
    });
  });
}
