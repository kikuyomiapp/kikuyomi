import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';

/// A cache file of [bytes] bytes, last read [ago] before now.
Future<File> aged(
  StreamAudioCache cache, {
  required int fileId,
  required Uri uri,
  required int bytes,
  required Duration ago,
}) async {
  final file = await cache.fileFor(fileId: fileId, uri: uri);
  await file.writeAsBytes(List.filled(bytes, 0));
  final at = DateTime.now().subtract(ago);
  await file.setLastAccessed(at);
  await file.setLastModified(at);
  return file;
}

void main() {
  late Directory folder;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('kikuyomi-stream-cache');
  });
  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  test('names a file after its id and where its bytes came from', () async {
    final cache = StreamAudioCache(folder);
    final one = await cache.fileFor(
      fileId: 7,
      uri: Uri.parse('https://archive.org/chapter-01.mp3'),
    );
    final again = await cache.fileFor(
      fileId: 7,
      uri: Uri.parse('https://archive.org/chapter-01.mp3'),
    );
    expect(one.path, again.path, reason: 'the same file, fetched again');
    expect(one.parent.path, folder.path);
  });

  test('a reused file id cannot serve the audio of another book', () async {
    final cache = StreamAudioCache(folder);
    final mine = await cache.fileFor(
      fileId: 7,
      uri: Uri.parse('https://archive.org/mine/chapter-01.mp3'),
    );
    final theirs = await cache.fileFor(
      fileId: 7,
      uri: Uri.parse('https://archive.org/theirs/chapter-01.mp3'),
    );
    expect(mine.path, isNot(theirs.path));
  });

  test(
    'a token that changes every time still finds what was fetched',
    () async {
      final cache = StreamAudioCache(folder);
      final first = await cache.fileFor(
        fileId: 7,
        uri: Uri.parse(
          'https://archive.org/chapter-01.mp3?token=abc&expires=1',
        ),
      );
      final second = await cache.fileFor(
        fileId: 7,
        uri: Uri.parse(
          'https://archive.org/chapter-01.mp3?token=xyz&expires=2',
        ),
      );
      expect(first.path, second.path);
    },
  );

  test('makes its folder when the first file is asked for', () async {
    final missing = Directory('${folder.path}${Platform.pathSeparator}streams');
    expect(missing.existsSync(), isFalse);
    await StreamAudioCache(missing)
        .fileFor(fileId: 1, uri: Uri.parse('https://archive.org/a.mp3'));
    expect(missing.existsSync(), isTrue);
  });

  test('pruning keeps what fits and takes the oldest first', () async {
    final cache = StreamAudioCache(folder, maxBytes: 1000);
    final oldest = await aged(
      cache,
      fileId: 1,
      uri: Uri.parse('https://archive.org/1.mp3'),
      bytes: 600,
      ago: const Duration(days: 3),
    );
    final older = await aged(
      cache,
      fileId: 2,
      uri: Uri.parse('https://archive.org/2.mp3'),
      bytes: 600,
      ago: const Duration(days: 2),
    );
    final newest = await aged(
      cache,
      fileId: 3,
      uri: Uri.parse('https://archive.org/3.mp3'),
      bytes: 600,
      ago: const Duration(minutes: 1),
    );

    await cache.prune();

    expect(oldest.existsSync(), isFalse);
    expect(older.existsSync(), isFalse);
    expect(newest.existsSync(), isTrue, reason: 'what fits stays');
  });

  test('pruning leaves everything alone while it fits', () async {
    final cache = StreamAudioCache(folder, maxBytes: 1000);
    final file = await aged(
      cache,
      fileId: 1,
      uri: Uri.parse('https://archive.org/1.mp3'),
      bytes: 900,
      ago: const Duration(days: 30),
    );
    await cache.prune();
    expect(file.existsSync(), isTrue);
  });

  test('a file still being fetched is never taken away', () async {
    final cache = StreamAudioCache(folder, maxBytes: 100);
    final fetching = await aged(
      cache,
      fileId: 1,
      uri: Uri.parse('https://archive.org/1.mp3'),
      bytes: 900,
      ago: const Duration(days: 3),
    );
    await File('${fetching.path}.part').writeAsBytes([0]);

    await cache.prune();

    expect(fetching.existsSync(), isTrue);
  });

  test('pruning a folder that is not there does nothing', () async {
    final missing = Directory('${folder.path}${Platform.pathSeparator}none');
    await StreamAudioCache(missing).prune();
    expect(missing.existsSync(), isFalse);
  });

  test('a pruned file takes its note of the media type with it', () async {
    final cache = StreamAudioCache(folder, maxBytes: 0);
    final file = await aged(
      cache,
      fileId: 1,
      uri: Uri.parse('https://archive.org/1.mp3'),
      bytes: 10,
      ago: const Duration(days: 1),
    );
    final mime = File('${file.path}.mime');
    await mime.writeAsString('audio/mpeg');

    await cache.prune();

    expect(file.existsSync(), isFalse);
    expect(mime.existsSync(), isFalse);
  });

  test('clearing empties it but leaves what is being fetched', () async {
    final cache = StreamAudioCache(folder);
    final gone = await aged(
      cache,
      fileId: 1,
      uri: Uri.parse('https://archive.org/1.mp3'),
      bytes: 10,
      ago: const Duration(minutes: 1),
    );
    final fetching = await aged(
      cache,
      fileId: 2,
      uri: Uri.parse('https://archive.org/2.mp3'),
      bytes: 10,
      ago: const Duration(minutes: 1),
    );
    await File('${fetching.path}.part').writeAsBytes([0]);

    await cache.clear();

    expect(gone.existsSync(), isFalse);
    expect(fetching.existsSync(), isTrue);
  });

  test('clearing a folder that is not there does nothing', () async {
    final missing = Directory('${folder.path}${Platform.pathSeparator}none');
    await StreamAudioCache(missing).clear();
    expect(missing.existsSync(), isFalse);
  });

  test('nothing but its own files is touched', () async {
    final cache = StreamAudioCache(folder, maxBytes: 0);
    final stranger = File('${folder.path}${Platform.pathSeparator}notes.txt');
    await stranger.writeAsString('not ours');

    await cache.prune();
    await cache.clear();

    expect(stranger.existsSync(), isTrue);
  });
}
