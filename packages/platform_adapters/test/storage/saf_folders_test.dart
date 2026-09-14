import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_platform_adapters/src/storage/device_folders.dart';
import 'package:kikuyomi_platform_adapters/src/storage/saf_folders.dart';

const tree =
    'content://provider/tree/primary%3ABackups/document/primary%3ABackups';

/// A document tree in memory, behaving as Android's own storage provider does where it matters:
/// renaming onto a taken name picks another name, and every call fails once the permission is gone.
final class FakeDocuments implements SafDocuments {
  final files = <String, Uint8List>{};
  final directories = <String>{};
  final calls = <String>[];

  var permitted = true;
  var treeExists = true;
  var renameSupported = true;

  /// When set, the next call of this name fails as a platform call does.
  String? failNext;

  void _call(String name) {
    calls.add(name);
    if (!permitted || !treeExists || failNext == name) {
      failNext = null;
      throw PlatformException(code: 'PluginError', message: '$name failed');
    }
  }

  String _uri(String name) => '$tree/$name';
  String _name(String uri) => uri.substring(tree.length + 1);

  @override
  Future<SafDocument?> pickTree() async =>
      const SafDocument(uri: tree, name: 'Backups', isDirectory: true);

  @override
  Future<bool> hasPermission(String treeUri) async => permitted;

  @override
  Future<SafDocument?> stat(String treeUri) async => treeExists
      ? const SafDocument(uri: tree, name: 'Backups', isDirectory: true)
      : null;

  @override
  Future<List<SafDocument>> list(String treeUri) async {
    _call('list');
    return [
      for (final MapEntry(:key, :value) in files.entries)
        SafDocument(
          uri: _uri(key),
          name: key,
          sizeBytes: value.length,
          modifiedAt: DateTime.utc(2026, 9, 14),
        ),
      for (final name in directories)
        SafDocument(uri: _uri(name), name: name, isDirectory: true),
    ];
  }

  @override
  Future<SafDocument?> child(String treeUri, String name) async {
    _call('child');
    return files.containsKey(name)
        ? SafDocument(uri: _uri(name), name: name)
        : null;
  }

  @override
  Future<Uint8List> read(String documentUri) async {
    _call('read');
    return files[_name(documentUri)]!;
  }

  @override
  Future<SafDocument> write(
    String treeUri,
    String name,
    Uint8List bytes,
  ) async {
    _call('write $name');
    files[name] = bytes;
    return SafDocument(uri: _uri(name), name: name);
  }

  @override
  Future<SafDocument> rename(String documentUri, String name) async {
    _call('rename $name');
    if (!renameSupported) {
      throw PlatformException(code: 'PluginError', message: 'no rename');
    }
    final bytes = files.remove(_name(documentUri))!;
    final given = files.containsKey(name) ? '$name (1)' : name;
    files[given] = bytes;
    return SafDocument(uri: _uri(given), name: given);
  }

  @override
  Future<void> delete(String documentUri) async {
    _call('delete ${_name(documentUri)}');
    files.remove(_name(documentUri));
  }
}

void main() {
  late FakeDocuments documents;
  late SafFolders folders;
  late UserFolder folder;

  setUp(() async {
    documents = FakeDocuments();
    folders = SafFolders(documents);
    folder = (await folders.choose())!;
  });

  test('keeps the tree and its name, and opens it again from its handle', () {
    expect(folder.displayName, 'Backups');
    final reopened = folders.open(folder.handle) as SafFolder;
    expect(reopened.uri, tree);
    expect(reopened.displayName, 'Backups');
  });

  test('lists only the files in the tree', () async {
    documents.files['one.bin'] = Uint8List.fromList([1, 2]);
    documents.directories.add('inner');

    final files = await folder.list();
    expect([for (final file in files) file.name], ['one.bin']);
    expect(files.single.sizeBytes, 2);
    expect(files.single.modifiedAt, DateTime.utc(2026, 9, 14));
  });

  test(
    'writes under a partial name, and renames the file once written',
    () async {
      await folder.write('one.bin', [1, 2, 3]);
      expect(documents.calls, [
        'write one.bin.partial',
        'child',
        'rename one.bin',
      ]);
      expect(documents.files.keys, ['one.bin']);
      expect(await folder.read('one.bin'), [1, 2, 3]);
    },
  );

  test('replaces a file of the same name', () async {
    documents.files['one.bin'] = Uint8List.fromList([9]);
    await folder.write('one.bin', [1]);
    expect(documents.files.keys, ['one.bin']);
    expect(documents.files['one.bin'], [1]);
  });

  test(
    'deletes the partial file when the folder cannot rename, and says why',
    () async {
      documents.renameSupported = false;
      await expectLater(
        folder.write('one.bin', [1]),
        throwsA(
          isA<FolderOperationException>().having(
            (e) => e.message,
            'message',
            contains('renamed'),
          ),
        ),
      );
      expect(documents.files, isEmpty);
    },
  );

  test('deletes a file, and deleting one not there does nothing', () async {
    documents.files['one.bin'] = Uint8List.fromList([1]);
    await folder.delete('one.bin');
    await folder.delete('one.bin');
    expect(documents.files, isEmpty);
  });

  group('when the permission is removed', () {
    setUp(() => documents.permitted = false);

    test('the folder is unreachable, saying why', () async {
      expect(
        await folder.checkAccess(),
        isA<FolderUnreachable>().having(
          (status) => status.reason,
          'reason',
          contains('permission'),
        ),
      );
    });

    test('its operations fail as unavailable', () async {
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

  test('a tree that no longer exists is unreachable', () async {
    documents.treeExists = false;
    expect(await folder.checkAccess(), isA<FolderUnreachable>());
    await expectLater(
      folder.read('one.bin'),
      throwsA(isA<FolderUnavailableException>()),
    );
  });

  test(
    'a failure while the folder can be reached is an operation failure',
    () async {
      documents.failNext = 'list';
      await expectLater(
        folder.list(),
        throwsA(isA<FolderOperationException>()),
      );
    },
  );

  test(
    'opens a handle written by another kind of device as unusable',
    () async {
      final unusable = folders.open(
        '{"kind":"directory","path":"C:\\\\Backups"}',
      );
      expect(await unusable.checkAccess(), isA<FolderUnreachable>());
    },
  );

  group('a device that cannot keep a folder yet', () {
    const unsupported = UnsupportedFolders();

    test('cannot choose one, and says so', () async {
      expect(unsupported.canChoose, isFalse);
      await expectLater(
        unsupported.choose(),
        throwsA(isA<FolderUnsupportedException>()),
      );
    });

    test('cannot use one chosen before', () async {
      final saved = unsupported.open(folder.handle);
      expect(await saved.checkAccess(), isA<FolderUnreachable>());
      await expectLater(
        saved.list(),
        throwsA(isA<FolderUnsupportedException>()),
      );
    });
  });
}
