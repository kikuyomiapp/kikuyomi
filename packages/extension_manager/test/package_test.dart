// Reading an extension package, and installing one into the app's own storage.
//
// One reader serves the three places a package is held — the app's assets, a folder on the device,
// and the app's own copy of an installed one — so these tests read from folders, which is the door
// this step opens, and from a store that holds the files in memory, which is what an asset bundle
// looks like from here.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kikuyomi_extension_manager/kikuyomi_extension_manager.dart';
import 'package:test/test.dart';

const code = 'export default { id: "x" };\n';

/// §3.3's own example, with the hash of [code] where the real thing has it.
Map<String, Object?> manifestData({Map<String, Object?> changed = const {}}) =>
    {
      'id': 'org.example.librivox',
      'name': 'LibriVox',
      'version': '1.4.0',
      'versionCode': 14,
      'apiVersion': '1.0',
      'minAppVersion': '1.0.0',
      'author': 'Example Maintainers',
      'contentRating': 'everyone',
      'domains': ['librivox.org', 'archive.org', '*.us.archive.org'],
      'capabilities': ['latest', 'filters'],
      'sources': [
        {'key': 'librivox', 'name': 'LibriVox', 'lang': 'en', 'versionId': 1},
      ],
      'files': {'main.js': sha256OfExtensionFile(utf8.encode(code))},
      ...changed,
    };

/// A package whose files are held in memory, as an asset bundle's are.
final class _Files implements ExtensionFiles {
  _Files(this.files);

  final Map<String, String> files;

  @override
  String get description => 'a package in memory';

  @override
  Future<Uint8List> read(String name) async {
    final content = files[name];
    if (content == null) {
      throw ExtensionPackageException(description, 'it has no $name');
    }
    return Uint8List.fromList(utf8.encode(content));
  }
}

_Files inMemory({String? manifest, String? main}) => _Files({
  if (manifest != null) 'manifest.json': manifest,
  if (main != null) 'main.js': main,
});

/// Writes a package into [folder] and returns it.
Future<Directory> writePackage(
  Directory folder, {
  String? manifest,
  String? main = code,
}) async {
  await folder.create(recursive: true);
  if (manifest != null) {
    await File('${folder.path}${Platform.pathSeparator}manifest.json')
        .writeAsString(manifest);
  }
  if (main != null) {
    await File('${folder.path}${Platform.pathSeparator}main.js')
        .writeAsString(main);
  }
  return folder;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kikuyomi_packages');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Directory at(String name) =>
      Directory('${temp.path}${Platform.pathSeparator}$name');

  group('reading a package', () {
    test('reads the manifest and the code', () async {
      final package = await readExtensionPackage(
        inMemory(manifest: jsonEncode(manifestData()), main: code),
        checkHashes: true,
      );

      expect(package.manifest.id, 'org.example.librivox');
      expect(package.manifest.sources.single.key, 'librivox');
      expect(package.code, code);
      expect(package.hashesChecked, isTrue);
    });

    test('keeps the manifest as it was written', () async {
      // Installing writes this back, so an extension's own file survives the round trip: a field a
      // later minor version adds is not dropped by this app's reading of it (§3.7).
      const written =
          '{"id": "org.example.librivox", "name": "LibriVox",\n'
          '"version": "1.4.0", "versionCode": 14, "apiVersion": "1.0",\n'
          '"minAppVersion": "1.0.0", "domains": [], "sources": [{"key": "l",\n'
          '"name": "L", "lang": "en", "versionId": 1}], "somethingNewer": 7}';

      final package = await readExtensionPackage(
        inMemory(manifest: written, main: code),
        checkHashes: false,
      );

      expect(package.manifestJson, written);
    });

    test('refuses a manifest that cannot be read', () {
      expect(
        readExtensionPackage(
          inMemory(manifest: 'not json', main: code),
          checkHashes: false,
        ),
        throwsA(isA<ManifestException>()),
      );
    });

    test('refuses a package with no code at all', () {
      expect(
        readExtensionPackage(
          inMemory(manifest: jsonEncode(manifestData())),
          checkHashes: false,
        ),
        throwsA(isA<ExtensionPackageException>()),
      );
    });

    test('refuses code the manifest does not describe', () {
      expect(
        readExtensionPackage(
          inMemory(manifest: jsonEncode(manifestData()), main: 'edited();'),
          checkHashes: true,
        ),
        throwsA(
          isA<ExtensionPackageException>().having(
            (e) => e.message,
            'message',
            contains('its manifest says'),
          ),
        ),
      );
    });

    test('refuses a manifest that names no code', () {
      expect(
        readExtensionPackage(
          inMemory(
            manifest: jsonEncode(manifestData(changed: {'files': {}})),
            main: code,
          ),
          checkHashes: true,
        ),
        throwsA(
          isA<ExtensionPackageException>().having(
            (e) => e.message,
            'message',
            contains('does not list main.js'),
          ),
        ),
      );
    });

    test(
      'reads code the manifest does not describe when hashes are not checked',
      () async {
        // What a folder an author is working in looks like: main.js edited, the manifest left
        // behind. It reads, and says that nothing was checked.
        final package = await readExtensionPackage(
          inMemory(manifest: jsonEncode(manifestData()), main: 'edited();'),
          checkHashes: false,
        );

        expect(package.code, 'edited();');
        expect(package.hashesChecked, isFalse);
      },
    );

    test('reads a package from a folder', () async {
      final folder = await writePackage(
        at('librivox'),
        manifest: jsonEncode(manifestData()),
      );

      final package = await readExtensionPackage(
        DirectoryExtensionFiles(folder),
        checkHashes: true,
      );

      expect(package.manifest.id, 'org.example.librivox');
      expect(package.code, code);
    });

    test('names the folder when one of its files is missing', () async {
      final folder = await writePackage(at('librivox'), main: null);

      await expectLater(
        readExtensionPackage(
          DirectoryExtensionFiles(folder),
          checkHashes: false,
        ),
        throwsA(
          isA<ExtensionPackageException>().having(
            (e) => '$e',
            'message',
            allOf(contains(folder.path), contains('manifest.json')),
          ),
        ),
      );
    });

    test(
      'a folder with a manifest is worth offering, and one without is not',
      () async {
        final package = await writePackage(
          at('librivox'),
          manifest: jsonEncode(manifestData()),
        );
        final books = await at('books').create();

        expect(await DirectoryExtensionFiles.looksLikeOne(package), isTrue);
        expect(await DirectoryExtensionFiles.looksLikeOne(books), isFalse);
      },
    );
  });

  group('installing', () {
    late ExtensionInstallFolder installs;

    setUp(() => installs = ExtensionInstallFolder(at('installed')));

    Future<ExtensionPackage> packageIn(
      Directory folder, {
      Map<String, Object?> changed = const {},
      String main = code,
    }) async => readExtensionPackage(
      DirectoryExtensionFiles(
        await writePackage(
          folder,
          manifest: jsonEncode(manifestData(changed: changed)),
          main: main,
        ),
      ),
      checkHashes: false,
    );

    test('keeps a copy the app owns, under its version', () async {
      final package = await packageIn(at('source'));

      final installPath = await installs.write(package);

      expect(installPath, 'org.example.librivox/14');
      final installed = await readExtensionPackage(
        installs.filesAt(installPath),
        checkHashes: true,
      );
      expect(installed.code, code);
      expect(installed.manifest.version.toString(), '1.4.0');
    });

    test('the copy outlives the folder it came from', () async {
      final folder = at('source');
      final installPath = await installs.write(await packageIn(folder));

      await folder.delete(recursive: true);

      final installed = await readExtensionPackage(
        installs.filesAt(installPath),
        checkHashes: false,
      );
      expect(installed.code, code);
    });

    test('installing the same version again replaces it', () async {
      final folder = at('source');
      final first = await installs.write(await packageIn(folder));
      await folder.delete(recursive: true);

      final again = await installs.write(
        await packageIn(folder, main: 'edited();'),
      );

      expect(again, first);
      final installed = await readExtensionPackage(
        installs.filesAt(again),
        checkHashes: false,
      );
      expect(installed.code, 'edited();');
    });

    test('a newer version is installed beside the one in use (§3.9)', () async {
      final old = await installs.write(await packageIn(at('old')));
      final new_ = await installs.write(
        await packageIn(
          at('new'),
          changed: {'version': '1.5.0', 'versionCode': 15},
        ),
      );

      expect(new_, isNot(old));
      expect(
        (await readExtensionPackage(
          installs.filesAt(old),
          checkHashes: false,
        )).manifest.versionCode,
        14,
      );
      expect(
        (await readExtensionPackage(
          installs.filesAt(new_),
          checkHashes: false,
        )).manifest.versionCode,
        15,
      );
    });

    test(
      'leaves nothing behind that looks installed when a write fails',
      () async {
        // The folder takes its real name only once both files are in it, so a half-written install is
        // never a folder the next start would read.
        final installPath = await installs.write(await packageIn(at('source')));
        final folder = Directory(
          '${installs.root.path}${Platform.pathSeparator}'
          '${installPath.replaceAll('/', Platform.pathSeparator)}',
        );

        expect(
          [
            for (final entry in await folder.list().toList())
              entry.path.split(RegExp(r'[\\/]')).last,
          ]..sort(),
          ['main.js', 'manifest.json'],
        );
        expect(
          await Directory('${folder.path}.partial').exists(),
          isFalse,
          reason: 'the partial folder is renamed, not left beside the real one',
        );
      },
    );

    test('removing an extension takes every version of it', () async {
      await installs.write(await packageIn(at('old')));
      await installs.write(
        await packageIn(
          at('new'),
          changed: {'version': '1.5.0', 'versionCode': 15},
        ),
      );

      await installs.deleteAll('org.example.librivox');

      expect(
        await Directory(
          '${installs.root.path}${Platform.pathSeparator}org.example.librivox',
        ).exists(),
        isFalse,
      );
    });

    test('removing an extension that is not installed does nothing', () async {
      await expectLater(installs.deleteAll('org.example.nothing'), completes);
    });
  });
}
