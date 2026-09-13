import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

void main() {
  late KikuyomiDatabase db;
  late LocalMediaResolver resolver;
  late Directory dir;
  final clock = FakeClock(DateTime.utc(2026, 9, 13, 20));

  setUp(() {
    db = KikuyomiDatabase(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('kikuyomi_resolver_test');
    resolver = LocalMediaResolver(db, mediaRoot: dir);
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<int> importAt(String path) async {
    await importLocalBook(
      db,
      LocalBookImport(
        file: LocalBookFile(path: path, durationMs: 1000),
        title: 'A Book',
      ),
      clock: clock,
    );
    return (await db.select(db.mediaFiles).getSingle()).id;
  }

  test('resolves a local file to a file URI', () async {
    final file = File('${dir.path}${Platform.pathSeparator}book.m4b')
      ..writeAsBytesSync([0]);
    final id = await importAt(file.path);
    final media = await resolver.resolve(id);
    expect(media.uri, Uri.file(file.path));
    expect(media.headers, isEmpty);
  });

  test('a file that has since disappeared is reported', () async {
    final id = await importAt('${dir.path}${Platform.pathSeparator}gone.m4b');
    expect(resolver.resolve(id), throwsA(isA<MediaUnavailableException>()));
  });

  test('a relative path is found under the media root', () async {
    await Directory('${dir.path}/Import').create();
    final file = File('${dir.path}/Import/book.m4b')..writeAsBytesSync([0]);
    final id = await importAt('Import/book.m4b');
    expect((await resolver.resolve(id)).uri, Uri.file(file.path));
  });

  test('a relative path survives the media root moving', () async {
    // On iOS an app's container can move when the app is updated, taking its files with it.
    final id = await importAt('Import/book.m4b');
    final moved = Directory.systemTemp.createTempSync(
      'kikuyomi_resolver_moved',
    );
    addTearDown(() => moved.deleteSync(recursive: true));
    await Directory('${moved.path}/Import').create();
    final file = File('${moved.path}/Import/book.m4b')..writeAsBytesSync([0]);

    final media = await LocalMediaResolver(db, mediaRoot: moved).resolve(id);
    expect(media.uri, Uri.file(file.path));
  });

  test('a relative path missing from the media root is reported', () async {
    final id = await importAt('Import/gone.m4b');
    expect(resolver.resolve(id), throwsA(isA<MediaUnavailableException>()));
  });

  test('a file that is not on this device is reported', () async {
    final file = File('${dir.path}${Platform.pathSeparator}book.m4b')
      ..writeAsBytesSync([0]);
    final id = await importAt(file.path);
    await (db.update(db.mediaFiles)..where((f) => f.id.equals(id))).write(
      const MediaFilesCompanion(localPath: Value(null)),
    );
    expect(resolver.resolve(id), throwsA(isA<MediaUnavailableException>()));
  });

  test('an unknown file id is reported', () async {
    expect(resolver.resolve(404), throwsA(isA<MediaUnavailableException>()));
  });
}
