import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:test/test.dart';

/// Local time three hours ahead of UTC, as in Beirut in summer, so that local and UTC dates differ
/// for three hours every day. The fields of the result are the local date and time.
DateTime localTime(DateTime instant) =>
    instant.toUtc().add(const Duration(hours: 3));

/// The instant that is [day] of September 2026 at [hour]:[minute], local time.
DateTime at(int day, int hour, [int minute = 0]) =>
    DateTime.utc(2026, 9, day, hour, minute).subtract(const Duration(hours: 3));

/// The name of a backup taken at [day] of September 2026 at [hour]:[minute], local time.
String backup(int day, int hour, [int minute = 0]) =>
    backupFileName(at(day, hour, minute));

List<String> deleted(List<String> names, {required DateTime now}) =>
    backupsToDelete(names, now: now, localTime: localTime);

void main() {
  test('keeps every backup while there are fewer than the limits', () {
    expect(deleted([backup(14, 9), backup(10, 9)], now: at(14, 12)), isEmpty);
    expect(deleted([], now: at(14, 12)), isEmpty);
  });

  test('keeps the newest three of a day, and deletes the rest of it', () {
    final today = [for (var hour = 8; hour <= 13; hour++) backup(14, hour)];
    expect(
      deleted(today, now: at(14, 14)),
      unorderedEquals([backup(14, 8), backup(14, 9), backup(14, 10)]),
    );
  });

  test(
    'keeps the newest backup from each of the past seven days, today included',
    () {
      final names = [
        for (var day = 5; day <= 14; day++) ...[
          backup(day, 8),
          if (day < 14) backup(day, 22),
        ],
      ];

      expect(
        deleted(names, now: at(14, 12)),
        unorderedEquals([
          // The three newest are the 8:00 of the 14th and both of the 13th. The 8th to the 12th keep
          // their 22:00, and everything before the 8th goes.
          for (var day = 8; day <= 12; day++) backup(day, 8),
          for (var day = 5; day <= 7; day++) ...[
            backup(day, 8),
            backup(day, 22),
          ],
        ]),
      );
    },
  );

  test('goes by local calendar days, not UTC ones', () {
    final names = [
      for (var hour = 9; hour <= 11; hour++) backup(20, hour),
      // Local dates of the 14th and 13th, both on the 13th in UTC.
      backup(14, 0, 30),
      backup(13, 23, 30),
    ];

    expect(deleted(names, now: at(20, 12)), [backup(13, 23, 30)]);
  });

  test('keeps the day of a backup just after local midnight apart from the '
      'day before', () {
    final names = [
      for (var hour = 9; hour <= 11; hour++) backup(14, hour),
      backup(13, 0, 30),
      backup(12, 23, 59),
    ];
    expect(deleted(names, now: at(14, 12)), isEmpty);
  });

  test('never deletes a file that is not a backup, however old', () {
    final names = [
      for (var hour = 9; hour <= 11; hour++) backup(14, hour),
      'notes.txt',
      '${backup(1, 9)}.partial',
      '${backup(1, 9)} (1)',
      'kikuyomi-backup-1999-01-01T00-00-00-000Z.tachibk',
      backup(1, 9),
    ];
    expect(deleted(names, now: at(14, 12)), [backup(1, 9)]);
  });

  test(
    'counts a backup dated after now among the newest, but in no past day',
    () {
      final names = [
        for (var day = 20; day <= 23; day++) backup(day, 9),
        backup(14, 9),
      ];
      expect(deleted(names, now: at(14, 12)), [backup(20, 9)]);
    },
  );

  test('follows the limits it is given', () {
    final names = [for (var day = 1; day <= 10; day++) backup(day, 9)];
    expect(
      backupsToDelete(
        names,
        now: at(10, 12),
        localTime: localTime,
        newest: 1,
        days: 2,
      ),
      unorderedEquals([for (var day = 1; day <= 8; day++) backup(day, 9)]),
    );
  });
}
