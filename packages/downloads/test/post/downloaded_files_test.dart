// Keeping a finished download, against real files on disk.
//
// The rule these hold to is §5.7's: nothing is recorded as downloaded until it is really here and
// really audio, because a chapter marked downloaded is one the listener will trust on a train.

import 'dart:io';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_downloads/kikuyomi_downloads.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory kept;
  late Directory incoming;
  late DownloadedFiles files;

  const subject = DownloadSubject(
    taskId: 1,
    mediaFileId: 100,
    bookId: 10,
    state: DownloadState.processing,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kikuyomi_downloaded');
    kept = await Directory('${temp.path}/kept').create();
    incoming = await Directory('${temp.path}/incoming').create();
    files = DownloadedFiles(kept);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// A finished download of [bytes], as the transport would leave it.
  Future<String> arrived(List<int> bytes, {String name = 'raw.tmp'}) async {
    final file = File('${incoming.path}/$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// A site's error page, at the size a real one is: kilobytes of markup, not a few characters.
  List<int> errorPage() => [
    ...'<!DOCTYPE html><html><body><h1>Not found</h1>'.codeUnits,
    ...List.filled(2048, 0x20),
    ...'</body></html>'.codeUnits,
  ];

  /// A plausible audio file: a real signature and enough bytes to pass the floor.
  List<int> audio([String signature = 'fLaC']) => [
    ...signature.codeUnits,
    ...List.filled(4096, 0),
  ];

  File keptFile(String relative) => File(
    '${kept.path}${Platform.pathSeparator}'
    '${relative.replaceAll('/', Platform.pathSeparator)}',
  );

  group('keeping one', () {
    test('names it after its book and its file, and says where', () async {
      final path = await arrived(audio());

      final relative = await files.keep(subject, path);

      expect(relative, '10/100.flac');
      expect(await keptFile(relative).exists(), isTrue);
    });

    test('the path it returns is relative, not absolute', () async {
      // For the reason a cover's path is: on iOS the app's container moves when the app is updated,
      // and an absolute path recorded today is wrong tomorrow.
      final relative = await files.keep(subject, await arrived(audio()));

      expect(relative, isNot(contains(kept.path)));
    });

    test('moves the bytes rather than copying them', () async {
      final path = await arrived(audio());

      await files.keep(subject, path);

      expect(
        await File(path).exists(),
        isFalse,
        reason: 'the transport’s copy is not left to fill the disk twice',
      );
    });

    test('keeps every byte', () async {
      final bytes = audio();
      final relative = await files.keep(subject, await arrived(bytes));

      expect(await keptFile(relative).readAsBytes(), bytes);
    });

    test('takes its extension from what the bytes say', () async {
      expect(
        await files.keep(subject, await arrived(audio('OggS'))),
        endsWith('.ogg'),
      );
    });

    test('falls back to the name the transport used', () async {
      // An unrecognised container is kept, so it still needs a name; the transport's own extension is
      // the best evidence left.
      final path = await arrived([
        0x1A,
        0x45,
        0xDF,
        0xA3,
        ...List.filled(4096, 0),
      ], name: 'chapter.m4b');

      expect(await files.keep(subject, path), endsWith('.m4b'));
    });

    test('and to something plain when there is nothing to go on', () async {
      final path = await arrived([
        0x1A,
        0x45,
        0xDF,
        0xA3,
        ...List.filled(4096, 0),
      ], name: 'chapter');

      expect(await files.keep(subject, path), endsWith('.audio'));
    });

    test('two files of one book sit together', () async {
      await files.keep(subject, await arrived(audio(), name: 'a'));
      await files.keep(
        const DownloadSubject(
          taskId: 2,
          mediaFileId: 101,
          bookId: 10,
          state: DownloadState.processing,
        ),
        await arrived(audio(), name: 'b'),
      );

      final folder = Directory('${kept.path}${Platform.pathSeparator}10');
      expect(await folder.list().length, 2);
    });
  });

  group('refusing one', () {
    test('a web page, however well it downloaded (§5.2)', () async {
      // Padded to the size of a real error page, so that it is the bytes that condemn it rather
      // than the floor: a site's "not found" page is kilobytes of markup, not fifty characters.
      final path = await arrived(errorPage());

      await expectLater(
        files.keep(subject, path),
        throwsA(
          isA<DownloadRefused>().having(
            (e) => e.reason,
            'reason',
            contains('a web page'),
          ),
        ),
      );
    });

    test('and keeps nothing behind', () async {
      final path = await arrived(errorPage());

      await expectLater(files.keep(subject, path), throwsA(anything));

      expect(
        await Directory('${kept.path}${Platform.pathSeparator}10').exists(),
        isFalse,
        reason: 'a refused download must not look like a downloaded book',
      );
    });

    test('a file the transport reported but did not leave', () async {
      await expectLater(
        files.keep(subject, '${incoming.path}/never-written'),
        throwsA(
          isA<DownloadRefused>().having(
            (e) => e.reason,
            'reason',
            contains('not there'),
          ),
        ),
      );
    });

    test('an empty file', () async {
      await expectLater(
        files.keep(subject, await arrived(const [])),
        throwsA(isA<DownloadRefused>()),
      );
    });
  });

  group('throwing one away (§5.6)', () {
    test('takes the file and the book folder with it', () async {
      final relative = await files.keep(subject, await arrived(audio()));

      await files.discard(relative);

      expect(await keptFile(relative).exists(), isFalse);
      expect(
        await Directory('${kept.path}${Platform.pathSeparator}10').exists(),
        isFalse,
      );
    });

    test('leaves the folder when the book still has another file', () async {
      final first = await files.keep(
        subject,
        await arrived(audio(), name: 'a'),
      );
      await files.keep(
        const DownloadSubject(
          taskId: 2,
          mediaFileId: 101,
          bookId: 10,
          state: DownloadState.processing,
        ),
        await arrived(audio(), name: 'b'),
      );

      await files.discard(first);

      expect(
        await Directory('${kept.path}${Platform.pathSeparator}10').exists(),
        isTrue,
      );
    });

    test('discarding what is not there is not a failure', () async {
      // A row and a file can disagree, and this is one of the places that settles it.
      await expectLater(files.discard('10/999.mp3'), completes);
    });
  });

  group('what it all comes to (§5.6)', () {
    test('is the size of everything kept', () async {
      await files.keep(subject, await arrived(audio(), name: 'a'));
      await files.keep(
        const DownloadSubject(
          taskId: 2,
          mediaFileId: 101,
          bookId: 11,
          state: DownloadState.processing,
        ),
        await arrived(audio(), name: 'b'),
      );

      expect(await files.totalBytes(), 2 * (4096 + 4));
    });

    test('is nothing when nothing has been downloaded', () async {
      expect(
        await DownloadedFiles(Directory('${temp.path}/never')).totalBytes(),
        0,
      );
    });
  });
}
