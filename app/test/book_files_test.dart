import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/book_files.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';

// Audio files built byte by byte, holding no recording: the readers' own tests cover the formats in
// depth, and these need only enough of each to be read.

List<int> le32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

/// A FLAC file of [seconds] at 44.1 kHz whose Vorbis comments are [comments].
List<int> flacFile(List<String> comments, {int seconds = 10}) {
  final streamInfo = [
    0x10, 0x00, 0x10, 0x00, // block sizes of 4096
    ...List.filled(6, 0), // frame sizes, unknown
    ...(ByteData(8)
          ..setUint64(0, 44100 << 44 | 1 << 41 | 15 << 36 | 44100 * seconds))
        .buffer
        .asUint8List(),
    ...List.filled(16, 0), // MD5
  ];
  final vendor = utf8.encode('tests');
  final commentBlock = [
    ...le32(vendor.length),
    ...vendor,
    ...le32(comments.length),
    for (final comment in comments) ...[
      ...le32(utf8.encode(comment).length),
      ...utf8.encode(comment),
    ],
  ];
  return [
    ...ascii.encode('fLaC'),
    0x00,
    0,
    0,
    streamInfo.length,
    ...streamInfo,
    0x84,
    0,
    commentBlock.length >> 8,
    commentBlock.length & 0xFF,
    ...commentBlock,
  ];
}

/// An MP3 of 20 frames at 128 kbps with no tags: its duration is estimated.
final mp3File = [
  for (var i = 0; i < 20; i++) ...[
    0xFF,
    0xFB,
    0x90,
    0x00,
    ...List.filled(413, 0),
  ],
];

/// A device whose player plays MP3 and MPEG-4 but not FLAC.
const noFlac = PlayableFormats({AudioFormat.mp3, AudioFormat.mp4});

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kikuyomi_book_files_');
  });

  tearDown(() => root.delete(recursive: true));

  Future<File> put(String name, List<int> bytes) async {
    final file = File('${root.path}${Platform.pathSeparator}$name');
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes);
  }

  group('a file read as a book', () {
    test('gives its title, credits and chapters', () async {
      final book = await probeBookFile(
        await put(
          'book.flac',
          flacFile([
            'TITLE=Chapter One',
            'ALBUM=A Book',
            'ALBUMARTIST=An Author',
            'COMPOSER=A Narrator',
            'CHAPTER001=00:00:00.000',
            'CHAPTER001NAME=Opening',
            'CHAPTER002=00:00:04.000',
            'CHAPTER002NAME=Closing',
          ]),
        ),
        PlayableFormats.all,
      );
      expect(book.durationMs, 10000);
      expect(book.durationIsEstimate, isFalse);
      expect(book.bookTitle, 'A Book');
      expect(book.author, 'An Author');
      expect(book.narrator, 'A Narrator');
      expect(
        [for (final m in book.markers) (m.startMs, m.title)],
        [(0, 'Opening'), (4000, 'Closing')],
      );
    });

    test('is refused, naming its format, where it cannot play', () async {
      final file = await put('book.flac', flacFile(const ['ALBUM=A Book']));
      await expectLater(
        probeBookFile(file, noFlac),
        throwsA(
          isA<UnplayableFormatException>()
              .having((e) => e.formats, 'formats', {AudioFormat.flac})
              .having(
                (e) => e.message,
                'message',
                'this device cannot play FLAC audio',
              ),
        ),
      );
    });

    test('is refused when it is not what its name says', () async {
      final file = await put('book.flac', mp3File);
      await expectLater(
        probeBookFile(file, PlayableFormats.all),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            endsWith('is not a FLAC file'),
          ),
        ),
      );
    });
  });

  group('a folder read as a book', () {
    Directory folder() =>
        Directory('${root.path}${Platform.pathSeparator}Book');

    test('leaves out the files the device cannot play, naming them', () async {
      await put('Book/01.mp3', mp3File);
      await put('Book/02.flac', flacFile(const []));

      final book = (await readPlayableFolder(folder(), noFlac))!;
      expect([for (final t in book.tracks) t.fileName], ['01.mp3']);
      final leftOut = LeftOut.of(book);
      expect(leftOut.unplayable, [
        (fileName: '02.flac', format: AudioFormat.flac),
      ]);
      expect(leftOut.describe(), 'FLAC files this device cannot play: 02.flac');
    });

    test('is refused, naming the format, when none of it can play', () async {
      await put('Book/01.flac', flacFile(const []));
      await put('Book/02.flac', flacFile(const []));
      await expectLater(
        readPlayableFolder(folder(), noFlac),
        throwsA(
          isA<UnplayableFormatException>().having((e) => e.formats, 'formats', {
            AudioFormat.flac,
          }),
        ),
      );
    });

    test('takes every file the device can play', () async {
      await put('Book/01.mp3', mp3File);
      await put('Book/02.flac', flacFile(const []));
      final book = (await readPlayableFolder(folder(), PlayableFormats.all))!;
      expect(book.tracks, hasLength(2));
      expect(LeftOut.of(book).isEmpty, isTrue);
    });

    test('is nothing when it holds no audio', () async {
      await put('Book/notes.txt', utf8.encode('Read by a volunteer.'));
      expect(await readPlayableFolder(folder(), noFlac), isNull);
    });
  });

  group('what was left out of a book', () {
    test('is nothing when nothing was', () {
      expect(LeftOut.none.isEmpty, isTrue);
      expect(LeftOut.none.describe(), '');
    });

    test('says what could not be read and what cannot play, by format', () {
      const leftOut = LeftOut(
        unreadable: ['03.mp3'],
        unplayable: [
          (fileName: '05.opus', format: AudioFormat.oggOpus),
          (fileName: '04.ogg', format: AudioFormat.oggVorbis),
        ],
      );
      expect(
        leftOut.describe(),
        'files it could not read: 03.mp3, and Ogg Vorbis and Ogg Opus files '
        'this device cannot play: 05.opus, 04.ogg',
      );
    });
  });

  test('looking in the import folder says what it added and what cannot play', () {
    expect(
      summarizeImportScan((added: 0, unplayable: const [])),
      'No new books in the Import folder',
    );
    expect(
      summarizeImportScan((
        added: 1,
        unplayable: [
          (
            name: 'Book.ogg',
            reason: UnplayableFormatException([AudioFormat.oggVorbis]),
          ),
          (
            name: 'A Folder',
            reason: UnplayableFormatException([
              AudioFormat.oggOpus,
              AudioFormat.oggVorbis,
            ]),
          ),
        ],
      )),
      'Added a book from the Import folder. '
      'Could not add Book.ogg: this device cannot play Ogg Vorbis audio. '
      'Could not add A Folder: this device cannot play Ogg Vorbis or Ogg Opus '
      'audio',
    );
    expect(
      summarizeImportScan((added: 3, unplayable: const [])),
      'Added 3 books from the Import folder',
    );
  });

  test('a failure to add a book is told in words', () {
    expect(
      describeAddError(UnplayableFormatException([AudioFormat.oggOpus])),
      'this device cannot play Ogg Opus audio',
    );
    expect(
      describeAddError(const FormatException('not audio')),
      'FormatException: not audio',
    );
  });

  test('every format the readers find has its own name in the domain', () {
    expect({
      for (final format in LocalAudioFormat.values) audioFormatOf(format),
    }, hasLength(LocalAudioFormat.values.length));
  });
}
