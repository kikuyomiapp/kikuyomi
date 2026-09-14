import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('reads back what was written, and nothing before', () async {
    final store = await SharedPreferencesSettingsStore.open();
    expect(store.read(AppSettings.backupSetup), isNull);

    await store.write(AppSettings.backupSetup, BackupSetup.completed);
    expect(store.read(AppSettings.backupSetup), BackupSetup.completed);
  });

  test('sees a write as soon as it is started', () async {
    final store = await SharedPreferencesSettingsStore.open();
    final written = store.write(AppSettings.backupDue, true);
    expect(store.read(AppSettings.backupDue), isTrue);
    await written;
  });

  test('keeps settings for the next time it opens', () async {
    final first = await SharedPreferencesSettingsStore.open();
    await first.write(AppSettings.lastBackupAt, DateTime.utc(2026, 9, 14));

    final next = await SharedPreferencesSettingsStore.open();
    expect(next.read(AppSettings.lastBackupAt), DateTime.utc(2026, 9, 14));
  });

  test('clears a setting written as null', () async {
    final store = await SharedPreferencesSettingsStore.open();
    await store.write(AppSettings.backupFolder, 'somewhere');
    await store.write(AppSettings.backupFolder, null);

    final next = await SharedPreferencesSettingsStore.open();
    expect(next.read(AppSettings.backupFolder), isNull);
  });

  test('reads a value stored as anything but text as not set', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
          AppSettings.backupDue.key: true,
          AppSettings.backupSetup.key: 'postponed',
        });
    final store = await SharedPreferencesSettingsStore.open();
    expect(store.read(AppSettings.backupDue), isNull);
    expect(store.read(AppSettings.backupSetup), isNull);
  });

  test('tells a watcher the value now, and after each write', () async {
    final store = await SharedPreferencesSettingsStore.open();
    final seen = <String?>[];
    final subscription = store.watch(AppSettings.backupFolder).listen(seen.add);
    addTearDown(subscription.cancel);

    await store.write(AppSettings.backupFolder, 'one');
    await store.write(AppSettings.lastBackupAt, DateTime.utc(2026));
    await store.write(AppSettings.backupFolder, null);
    await pumpEventQueue();

    expect(seen, [null, 'one', null]);
  });
}
