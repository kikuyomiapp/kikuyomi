import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_platform_adapters/src/storage/directory_folders.dart';

void main() {
  late Directory root;
  late DirectoryFolders folders;
  late UserFolder folder;

  String inRoot(String name) => '${root.path}${Platform.pathSeparator}$name';

  List<String> namesInRoot() => [
    for (final entry in root.listSync())
      entry.path.split(Platform.pathSeparator).last,
  ]..sort();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kikuyomi_folder_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    folders = DirectoryFolders(pickDirectory: () async => root.path);
    folder = (await folders.choose())!;
  });

  test('chooses the folder picked, and opens it again from its handle', () {
    expect(folder.displayName, root.absolute.path);
    final reopened = folders.open(folder.handle);
    expect(reopened.displayName, folder.displayName);
    expect(reopened.handle, folder.handle);
  });

  test('chooses nothing when the picker is cancelled', () async {
    final cancelled = DirectoryFolders(pickDirectory: () async => null);
    expect(await cancelled.choose(), isNull);
  });

  test('lists the files in it, with their sizes and times', () async {
    await File(inRoot('one.bin')).writeAsBytes([1, 2, 3]);
    await Directory(inRoot('inner')).create();

    final files = await folder.list();
    expect([for (final file in files) file.name], ['one.bin']);
    expect(files.single.sizeBytes, 3);
    expect(files.single.modifiedAt, isNotNull);
  });

  test('writes a file, leaving nothing else behind', () async {
    await folder.write('one.bin', [1, 2, 3]);
    expect(namesInRoot(), ['one.bin']);
    expect(await folder.read('one.bin'), [1, 2, 3]);
  });

  test('replaces a file of the same name', () async {
    await folder.write('one.bin', [1, 2, 3]);
    await folder.write('one.bin', [4]);
    expect(await folder.read('one.bin'), [4]);
    expect(namesInRoot(), ['one.bin']);
  });

  test(
    'leaves no partial file when a write cannot finish, and says why',
    () async {
      // A folder already has the name, so the finished file cannot take it.
      await Directory(inRoot('one.bin')).create();

      await expectLater(
        folder.write('one.bin', [1, 2, 3]),
        throwsA(isA<FolderOperationException>()),
      );
      expect(namesInRoot(), ['one.bin']);
      expect(await Directory(inRoot('one.bin')).exists(), isTrue);
    },
  );

  test('deletes a file, and deleting one not there does nothing', () async {
    await folder.write('one.bin', [1]);
    await folder.delete('one.bin');
    await folder.delete('one.bin');
    expect(namesInRoot(), isEmpty);
  });

  test('says there is no such file when reading one not there', () async {
    await expectLater(
      folder.read('missing.bin'),
      throwsA(isA<FolderOperationException>()),
    );
  });

  test('refuses a name that is not a file directly inside it', () {
    expect(() => folder.write('../one.bin', [1]), throwsArgumentError);
    expect(() => folder.read(r'inner\one.bin'), throwsArgumentError);
    expect(() => folder.delete(''), throwsArgumentError);
  });

  group('a folder deleted since it was chosen', () {
    setUp(() => root.delete(recursive: true));

    test('is reported as unreachable', () async {
      expect(await folder.checkAccess(), isA<FolderUnreachable>());
    });

    test('fails every operation as unavailable', () async {
      await expectLater(
        folder.list(),
        throwsA(isA<FolderUnavailableException>()),
      );
      await expectLater(
        folder.write('one.bin', [1]),
        throwsA(isA<FolderUnavailableException>()),
      );
    });
  });

  test('is reachable while it is there', () async {
    expect(await folder.checkAccess(), isA<FolderReachable>());
  });

  test(
    'opens a handle it cannot read as a folder that cannot be reached',
    () async {
      for (final handle in [
        'not json',
        '{"kind":"saf-tree","uri":"content://x","name":"x"}',
        '{"kind":"directory"}',
      ]) {
        final unusable = folders.open(handle);
        expect(await unusable.checkAccess(), isA<FolderUnreachable>());
        await expectLater(
          unusable.list(),
          throwsA(isA<FolderUnavailableException>()),
        );
      }
    },
  );
}
