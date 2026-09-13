import 'dart:io';
import 'dart:typed_data';

import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory mediaRoot;
  late ImportFolder folder;
  var picks = 0;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kikuyomi_import_');
    mediaRoot = await Directory('${temp.path}/media').create();
    folder = ImportFolder(mediaRoot: mediaRoot);
  });

  tearDown(() => temp.delete(recursive: true));

  /// A file as a picker hands it over: a copy in a folder of its own. [seed] varies the content.
  Future<File> picked(String name, {int seed = 1}) async {
    final directory = await Directory('${temp.path}/picker/${picks++}')
        .create(recursive: true);
    final bytes = Uint8List(200 * 1024);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * seed + seed) & 0xFF;
    }
    return File('${directory.path}/$name').writeAsBytes(bytes);
  }

  test(
    'moves the copy into the folder and returns its relative path',
    () async {
      final copy = await picked('A Book.m4b');
      final bytes = await copy.readAsBytes();

      final stored = await folder.adoptCopy(copy);

      expect(stored, 'Import/A Book.m4b');
      expect(await copy.exists(), isFalse);
      expect(await File('${mediaRoot.path}/$stored').readAsBytes(), bytes);
    },
  );

  test('the same book added twice is kept once', () async {
    final first = await folder.adoptCopy(await picked('A Book.m4b'));
    final again = await picked('A Book.m4b');

    expect(await folder.adoptCopy(again), first);
    expect(await again.exists(), isFalse, reason: 'the second copy is spare');
    expect(Directory('${mediaRoot.path}/Import').listSync(), hasLength(1));
  });

  test('a different book with the same name gets a numbered name', () async {
    await folder.adoptCopy(await picked('A Book.m4b', seed: 1));
    expect(
      await folder.adoptCopy(await picked('A Book.m4b', seed: 3)),
      'Import/A Book (2).m4b',
    );
  });

  test(
    'a book differing only in its closing bytes is a different book',
    () async {
      await folder.adoptCopy(await picked('A Book.m4b'));
      final other = await picked('A Book.m4b');
      final bytes = await other.readAsBytes();
      bytes[bytes.length - 1] ^= 0xFF;
      await other.writeAsBytes(bytes);

      expect(await folder.adoptCopy(other), 'Import/A Book (2).m4b');
    },
  );

  test('a name without an extension is numbered at its end', () async {
    await folder.adoptCopy(await picked('book', seed: 1));
    expect(
      await folder.adoptCopy(await picked('book', seed: 3)),
      'Import/book (2)',
    );
  });
}
