// What is installed, and what an extension has stored: the two things schema version 2 exists to
// keep across a restart.
//
// The rule these tests are really about is §3.9's: uninstalling removes the code and nothing else. So
// several of them remove an extension and then check what is still there.

import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

void main() {
  late KikuyomiDatabase db;
  late FakeClock clock;

  setUp(() {
    db = KikuyomiDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    clock = FakeClock(DateTime.utc(2026, 9, 23, 10));
  });

  Future<void> install({
    String id = 'org.example.librivox',
    String name = 'LibriVox',
    String version = '1.4.0',
    int versionCode = 14,
    ExtensionStatus status = ExtensionStatus.untrusted,
    ExtensionOrigin origin = ExtensionOrigin.folder,
    String? originHandle = r'G:\work\librivox',
    String? originName = r'G:\work\librivox',
    String? installPath,
  }) => recordInstalledExtension(
    db,
    id: id,
    name: name,
    version: version,
    versionCode: versionCode,
    apiVersion: '1.0',
    status: status,
    origin: origin,
    originHandle: originHandle,
    originName: originName,
    installPath: installPath ?? '$id/$versionCode',
    clock: clock,
  );

  group('what is installed', () {
    test('survives as the row the next start reads', () async {
      await install();

      final row = await readInstalledExtension(db, 'org.example.librivox');

      expect(row, isNotNull);
      expect(row!.name, 'LibriVox');
      expect(row.version, '1.4.0');
      expect(row.versionCode, 14);
      expect(row.apiVersion, '1.0');
      expect(row.status, ExtensionStatus.untrusted);
      expect(row.origin, ExtensionOrigin.folder);
      expect(row.originHandle, r'G:\work\librivox');
      expect(row.installPath, 'org.example.librivox/14');
      expect(row.installedAt, clock.now());
    });

    test('is one row per extension, holding the version in use', () async {
      await install();
      clock.advance(const Duration(days: 1));

      await install(version: '1.5.0', versionCode: 15);

      final rows = await readInstalledExtensions(db);
      expect(rows, hasLength(1));
      expect(rows.single.version, '1.5.0');
      expect(rows.single.installPath, 'org.example.librivox/15');
      expect(rows.single.installedAt, clock.now());
    });

    test('is listed by name', () async {
      await install(id: 'org.example.zed', name: 'Zed');
      await install(id: 'org.example.alpha', name: 'Alpha');

      expect(
        [for (final row in await readInstalledExtensions(db)) row.name],
        ['Alpha', 'Zed'],
      );
    });

    test('is watched, so a screen follows an install', () async {
      final seen = <int>[];
      final subscription = watchInstalledExtensions(db)
          .listen((rows) => seen.add(rows.length));
      addTearDown(subscription.cancel);

      await pumpEventQueue();
      await install();
      await pumpEventQueue();

      expect(seen, [0, 1]);
    });

    test('says nothing about an extension that is not installed', () async {
      expect(await readInstalledExtension(db, 'org.example.nothing'), isNull);
      expect(await readInstalledExtensions(db), isEmpty);
    });

    test('can be marked as no longer allowed to run', () async {
      await install(status: ExtensionStatus.active);

      await setExtensionStatus(
        db,
        'org.example.librivox',
        ExtensionStatus.obsolete,
      );

      final row = await readInstalledExtension(db, 'org.example.librivox');
      expect(row!.status, ExtensionStatus.obsolete);
      expect(row.status.canRun, isFalse);
    });
  });

  group('removing an extension', () {
    test('says whether it was installed at all', () async {
      await install();

      expect(
        await forgetInstalledExtension(db, 'org.example.librivox'),
        isTrue,
      );
      expect(
        await forgetInstalledExtension(db, 'org.example.librivox'),
        isFalse,
      );
    });

    test('leaves the sources its books point at (§3.9)', () async {
      await install();
      await registerSource(
        db,
        id: 7,
        key: 'librivox',
        name: 'LibriVox',
        lang: 'en',
        extensionId: 'org.example.librivox',
      );

      await forgetInstalledExtension(db, 'org.example.librivox');

      final source = (await readRegisteredSources(db)).single;
      expect(source.id, 7);
      expect(
        source.extensionId,
        'org.example.librivox',
        reason: 'the source remembers which extension it wants back',
      );
    });

    test('leaves what the extension had stored', () async {
      const store = 'org.example.librivox';
      await install();
      await ExtensionPreferenceStore(db)
          .write(store, 'catalogue', 'audiobooks');

      await forgetInstalledExtension(db, store);

      expect(await ExtensionPreferenceStore(db).readAll(store), {
        'catalogue': 'audiobooks',
      });
    });
  });

  group('what an extension stores', () {
    late ExtensionPreferenceStore store;
    const librivox = 'org.example.librivox';
    const archive = 'org.example.archive';

    setUp(() => store = ExtensionPreferenceStore(db));

    test('reads back what was written', () async {
      await store.write(librivox, 'catalogue', 'audiobooks');
      await store.write(librivox, 'since', '2026');

      expect(await store.readAll(librivox), {
        'catalogue': 'audiobooks',
        'since': '2026',
      });
    });

    test('is one namespace per extension', () async {
      await store.write(librivox, 'catalogue', 'audiobooks');
      await store.write(archive, 'catalogue', 'texts');

      expect(await store.readAll(librivox), {'catalogue': 'audiobooks'});
      expect(await store.readAll(archive), {'catalogue': 'texts'});
    });

    test('writing a key again replaces its value', () async {
      await store.write(librivox, 'catalogue', 'audiobooks');
      await store.write(librivox, 'catalogue', 'poetry');

      expect(await store.readAll(librivox), {'catalogue': 'poetry'});
    });

    test(
      'removing a value leaves the rest, and the other extensions',
      () async {
        await store.write(librivox, 'catalogue', 'audiobooks');
        await store.write(librivox, 'since', '2026');
        await store.write(archive, 'catalogue', 'texts');

        await store.remove(librivox, 'catalogue');

        expect(await store.readAll(librivox), {'since': '2026'});
        expect(await store.readAll(archive), {'catalogue': 'texts'});
      },
    );

    test('removing what is not there is not a failure', () async {
      await expectLater(store.remove(librivox, 'nothing'), completes);
    });

    test('an extension that stored nothing reads as empty', () async {
      expect(await store.readAll(librivox), isEmpty);
    });

    test('clearing throws away one extension, and says how much', () async {
      await store.write(librivox, 'catalogue', 'audiobooks');
      await store.write(librivox, 'since', '2026');
      await store.write(archive, 'catalogue', 'texts');

      expect(await store.clear(librivox), 2);
      expect(await store.readAll(librivox), isEmpty);
      expect(await store.readAll(archive), {'catalogue': 'texts'});
    });
  });
}
