import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:test/test.dart';

/// [value] as [setting] stores it and reads it back.
T? roundTrip<T extends Object>(Setting<T> setting, T value) =>
    setting.decode(setting.encode(value));

void main() {
  test('every setting has a key of its own', () {
    final keys = [for (final setting in AppSettings.all) setting.key];
    expect(keys.toSet(), hasLength(keys.length));
  });

  test('each setting reads back what it stored', () {
    expect(
      roundTrip(AppSettings.backupFolder, '{"kind":"directory"}'),
      '{"kind":"directory"}',
    );
    expect(
      roundTrip(AppSettings.lastBackupAt, DateTime.utc(2026, 9, 14, 15, 30)),
      DateTime.utc(2026, 9, 14, 15, 30),
    );
    expect(roundTrip(AppSettings.backupDue, true), isTrue);
    expect(roundTrip(AppSettings.backupDue, false), isFalse);
    expect(
      roundTrip(AppSettings.backupSetup, BackupSetup.skipped),
      BackupSetup.skipped,
    );
    expect(roundTrip(AppSettings.listenedBackfilled, true), isTrue);
  });

  test('a time is read back as the same instant, in UTC', () {
    final local = DateTime(2026, 9, 14, 18, 30);
    final read = roundTrip(AppSettings.lastBackupAt, local)!;
    expect(read.isAtSameMomentAs(local), isTrue);
    expect(read.isUtc, isTrue);
  });

  test('a stored value this build cannot read reads as not set', () {
    expect(AppSettings.lastBackupAt.decode('yesterday'), isNull);
    expect(AppSettings.lastBackupAt.decode('99999999999999999'), isNull);
    expect(AppSettings.backupDue.decode('yes'), isNull);
    expect(AppSettings.backupSetup.decode('postponed'), isNull);
  });
}
