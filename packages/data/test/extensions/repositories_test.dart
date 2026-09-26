// The repositories a listener has added, against a real database.
//
// Two properties carry the weight. One address is one repository, because `RepositoryLocation`
// normalises what was typed and the unique key is what turns that into a refusal rather than two
// rows refreshing each other's extensions. And a pinned key changes only where somebody decided it
// should: §3.8's trust is trust on first use, so a rotation happening as a side effect of a refresh
// would quietly undo the whole thing.

import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:test/test.dart';

final _at = DateTime.utc(2026, 9, 26, 9);

void main() {
  late KikuyomiDatabase db;

  setUp(() {
    db = KikuyomiDatabase(NativeDatabase.memory());
    addTearDown(db.close);
  });

  Future<int> add({
    String url = 'https://example.org/repo/',
    String name = 'Kikuyomi official',
    String publicKey = 'a2V5',
    String fingerprint = 'AA:BB:CC',
  }) => addRepository(
    db,
    url: url,
    name: name,
    publicKey: publicKey,
    fingerprint: fingerprint,
  );

  Future<RepositoryRow> only() => db.select(db.repositories).getSingle();

  group('adding one', () {
    test('keeps what the listener accepted', () async {
      await add();

      final stored = await only();
      expect(stored.url, 'https://example.org/repo/');
      expect(stored.name, 'Kikuyomi official');
      expect(stored.publicKey, 'a2V5');
      expect(stored.fingerprint, 'AA:BB:CC');
      expect(stored.etag, isNull);
      expect(stored.lastFetchedAt, isNull);
    });

    test('the same address twice is refused', () async {
      await add();

      await expectLater(add(name: 'The same place'), throwsA(anything));
    });

    test('a different address is another repository', () async {
      await add();
      await add(url: 'https://elsewhere.example/repo/', name: 'Elsewhere');

      expect(await db.select(db.repositories).get(), hasLength(2));
    });
  });

  group('reading one back', () {
    test('by its address', () async {
      await add();

      expect(
        (await readRepositoryAt(db, 'https://example.org/repo/'))?.name,
        'Kikuyomi official',
      );
    });

    test('and nothing for one that was never added', () async {
      expect(await readRepositoryAt(db, 'https://nobody.example/'), isNull);
    });

    test('watched, in the order they were added', () async {
      await add(url: 'https://a.example/', name: 'First');
      await add(url: 'https://b.example/', name: 'Second');

      expect(
        [for (final repo in await watchRepositories(db).first) repo.name],
        ['First', 'Second'],
      );
    });

    test('and again when one is added', () async {
      // Subscribed and let settle before the insert: a stream asked for two emissions while the
      // insert is already in flight is a race, and the one that loses waits for a change that has
      // already happened.
      final seen = <int>[];
      final watching = watchRepositories(db)
          .listen((rows) => seen.add(rows.length));
      addTearDown(watching.cancel);
      await pumpEventQueue();

      await add();
      await pumpEventQueue();

      expect(seen, [0, 1]);
    });
  });

  group('recording a refresh', () {
    test('keeps the tag and when it happened', () async {
      final id = await add();

      await recordRepositoryFetch(db, id, at: _at, etag: '"v1"');

      final stored = await only();
      expect(stored.etag, '"v1"');
      expect(stored.lastFetchedAt, _at);
    });

    test('clears a tag the repository has stopped sending', () async {
      // Otherwise every later refresh would carry a tag the server no longer knows.
      final id = await add();
      await recordRepositoryFetch(db, id, at: _at, etag: '"v1"');

      await recordRepositoryFetch(db, id, at: _at);

      expect((await only()).etag, isNull);
    });

    test('takes a name a repository has changed', () async {
      final id = await add();

      await recordRepositoryFetch(db, id, at: _at, name: 'Renamed');

      expect((await only()).name, 'Renamed');
    });

    test('leaves the name alone when the fetch does not say', () async {
      final id = await add();

      await recordRepositoryFetch(db, id, at: _at);

      expect((await only()).name, 'Kikuyomi official');
    });

    test('never touches the pinned key', () async {
      // The property the whole of trust on first use rests on.
      final id = await add();

      await recordRepositoryFetch(db, id, at: _at, etag: '"v1"');

      final stored = await only();
      expect(stored.publicKey, 'a2V5');
      expect(stored.fingerprint, 'AA:BB:CC');
    });
  });

  group('accepting a new key', () {
    test('pins it, and the fingerprint shown with it', () async {
      final id = await add();

      await acceptNewKey(db, id, publicKey: 'bmV3', fingerprint: 'DD:EE:FF');

      final stored = await only();
      expect(stored.publicKey, 'bmV3');
      expect(stored.fingerprint, 'DD:EE:FF');
    });

    test('throws away the cached tag with it', () async {
      // An index signed by a new key is not the index that was cached under the old one.
      final id = await add();
      await recordRepositoryFetch(db, id, at: _at, etag: '"v1"');

      await acceptNewKey(db, id, publicKey: 'bmV3', fingerprint: 'DD:EE:FF');

      expect((await only()).etag, isNull);
    });
  });

  group('removing one', () {
    test('takes only that repository', () async {
      final id = await add(url: 'https://a.example/', name: 'First');
      await add(url: 'https://b.example/', name: 'Second');

      await removeRepository(db, id);

      expect((await only()).name, 'Second');
    });

    test('removing one that has gone is not a failure', () async {
      await expectLater(removeRepository(db, 404), completes);
    });
  });
}
