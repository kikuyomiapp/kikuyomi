import 'dart:convert';
import 'dart:typed_data';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:test/test.dart';

import 'support/image_bytes.dart';
import 'support/mp3_bytes.dart' show id3, frame3;
import 'support/sparse_source.dart';
import 'support/vorbis_bytes.dart';

Future<FlacInfo?> info(List<int> bytes, {bool withCover = false}) =>
    readFlacInfo(
      MemoryByteSource(Uint8List.fromList(bytes)),
      withCover: withCover,
    );

/// A FLAC file with [comments] in its VORBIS_COMMENT block and some audio.
List<int> tagged(List<String> comments) => flac(
  info: streamInfo(totalSamples: 44100 * 10),
  blocks: [(4, vorbisComments(comments))],
  audio: List.filled(256, 0x5A),
);

/// A FLAC file whose STREAMINFO does not count its samples, ending in [audio].
List<int> uncounted(List<int> audio) => flac(
  info: streamInfo(totalSamples: 0),
  audio: [...List.filled(1000, 0x33), ...audio],
);

/// The body of a frame after its header: filler that holds no sync code.
final frameBody = List.filled(3000, 0x21);

void main() {
  group('duration', () {
    test('is counted from STREAMINFO, exactly', () async {
      final result = (await info(
        flac(info: streamInfo(totalSamples: 44100 * 90 + 22050)),
      ))!;
      expect(result.durationMs, 90500);
      expect(result.durationIsEstimate, isFalse);
      expect(result.sampleRate, 44100);
    });

    test('is counted at the rate STREAMINFO states', () async {
      final result = (await info(
        flac(info: streamInfo(sampleRate: 48000, totalSamples: 48000 * 3600)),
      ))!;
      expect(result.durationMs, 3600 * 1000);
    });

    group('when STREAMINFO does not count samples', () {
      test('is estimated from the last frame of fixed-size blocks', () async {
        final result = (await info(
          uncounted([
            ...frameHeader(number: 98),
            ...frameBody,
            ...frameHeader(number: 99),
            ...frameBody,
          ]),
        ))!;
        // Frames 0 to 99 of 4096 samples each.
        expect(result.durationMs, 100 * 4096 * 1000 ~/ 44100);
        expect(result.durationIsEstimate, isTrue);
      });

      test('is estimated from the last frame of variable blocks', () async {
        final result = (await info(
          uncounted([
            // A block size of 1000, in the 16 bits after the number that code 7 says follow.
            ...frameHeader(
              number: 441000,
              variable: true,
              blockSizeCode: 7,
              extra: [0x03, 0xE7],
            ),
            ...frameBody,
          ]),
        ))!;
        expect(result.durationMs, 442000 * 1000 ~/ 44100);
        expect(result.durationIsEstimate, isTrue);
      });

      test('passes over a sync code whose checksum fails', () async {
        final forged = frameHeader(number: 5000);
        forged[forged.length - 1] ^= 0xFF;
        final result = (await info(
          uncounted([
            ...frameHeader(number: 9),
            ...frameBody,
            ...forged,
            ...frameBody,
          ]),
        ))!;
        expect(result.durationMs, 10 * 4096 * 1000 ~/ 44100);
      });

      test('passes over a header that disagrees with STREAMINFO', () async {
        final result = (await info(
          uncounted([
            ...frameHeader(number: 9),
            ...frameBody,
            // 48 kHz, in a stream of 44.1 kHz.
            ...frameHeader(number: 5000, sampleRateCode: 10),
            ...frameBody,
          ]),
        ))!;
        expect(result.durationMs, 10 * 4096 * 1000 ~/ 44100);
      });

      test('is refused when no frame can be found near the end', () async {
        expect(
          info(uncounted(List.filled(4096, 0x21))),
          throwsA(isA<FormatException>()),
        );
      });
    });
  });

  group('tags', () {
    test('are read from the Vorbis comments', () async {
      final result = (await info(
        tagged([
          'TITLE=Chapter 3',
          'ARTIST=An Author',
          'ALBUMARTIST=An Album Artist',
          'ALBUM=A Book',
          'COMPOSER=A Narrator',
          'TRACKNUMBER=3/12',
          'DISCNUMBER=2',
        ]),
      ))!;
      expect(result.title, 'Chapter 3');
      expect(result.artist, 'An Author');
      expect(result.albumArtist, 'An Album Artist');
      expect(result.album, 'A Book');
      expect(result.composer, 'A Narrator');
      expect(result.trackNumber, 3);
      expect(result.discNumber, 2);
    });

    test('ignore the case of names, and keep the first of a name', () async {
      final result = (await info(
        tagged([
          'title=Café chapter',
          'Album Artist=An Author',
          'Title=A later title',
          'NOT A TAG',
        ]),
      ))!;
      expect(result.title, 'Café chapter');
      expect(result.albumArtist, 'An Author');
    });

    test('are simply absent when a file has none', () async {
      final result = (await info(flac(info: streamInfo(totalSamples: 44100))))!;
      expect(result.title, isNull);
      expect(result.album, isNull);
      expect(result.chapters, isEmpty);
    });
  });

  group('chapters', () {
    test('are read from CHAPTER comments, in order of their start', () async {
      final result = (await info(
        tagged([
          'CHAPTER002=00:01:02.5',
          'CHAPTER002NAME=The Middle',
          'CHAPTER001=00:00:00.000',
          'CHAPTER001NAME=The Start',
          'CHAPTER003=01:00:00',
          'CHAPTER003NAME=The End',
        ]),
      ))!;
      expect(result.chapters, const [
        EmbeddedChapter(startMs: 0, title: 'The Start'),
        EmbeddedChapter(startMs: 62500, title: 'The Middle'),
        EmbeddedChapter(startMs: 3600000, title: 'The End'),
      ]);
    });

    test('without a name are called by their place', () async {
      final result = (await info(
        tagged([
          'CHAPTER000=00:00:00.000',
          'CHAPTER001=00:10:00.000',
          'CHAPTER001NAME=Named',
          'CHAPTER002=not a time',
          'CHAPTER002NAME=Left out',
          'CHAPTER003=00:20:00.000',
        ]),
      ))!;
      expect(result.chapters, const [
        EmbeddedChapter(startMs: 0, title: 'Chapter 1'),
        EmbeddedChapter(startMs: 600000, title: 'Named'),
        EmbeddedChapter(startMs: 1200000, title: 'Chapter 3'),
      ]);
    });
  });

  group('cover', () {
    test('is not read unless asked for', () async {
      final result = (await info(
        flac(
          info: streamInfo(totalSamples: 44100),
          blocks: [(6, pictureStructure(image: jpegBytes()))],
        ),
      ))!;
      expect(result.cover, isNull);
    });

    test('is the picture marked as the front cover', () async {
      final front = pngBytes(fill: 0x44);
      final result = (await info(
        flac(
          info: streamInfo(totalSamples: 44100),
          blocks: [
            (6, pictureStructure(image: jpegBytes(), type: 4)),
            (6, pictureStructure(image: front, mimeType: 'image/png')),
          ],
        ),
        withCover: true,
      ))!;
      expect(result.cover!.mimeType, 'image/png');
      expect(result.cover!.bytes, front);
    });

    test('is the first picture when none is the front cover', () async {
      final first = jpegBytes(fill: 0x55);
      final result = (await info(
        flac(
          info: streamInfo(totalSamples: 44100),
          blocks: [
            (6, pictureStructure(image: first, type: 0)),
            (6, pictureStructure(image: pngBytes(), type: 4)),
          ],
        ),
        withCover: true,
      ))!;
      expect(result.cover!.bytes, first);
    });

    test('takes its type from its bytes over its stated MIME type', () async {
      final result = (await info(
        flac(
          info: streamInfo(totalSamples: 44100),
          blocks: [
            (6, pictureStructure(image: jpegBytes(), mimeType: 'image/png')),
          ],
        ),
        withCover: true,
      ))!;
      expect(result.cover!.mimeType, 'image/jpeg');
    });

    test(
      'is read from a picture comment when there is no picture block',
      () async {
        final image = jpegBytes(length: 5000, fill: 0x66);
        final result = (await info(
          tagged(['TITLE=A Book', pictureComment(image: image)]),
          withCover: true,
        ))!;
        expect(result.title, 'A Book');
        expect(result.cover!.bytes, image);
      },
    );

    test('is none when the picture is only a link to one', () async {
      final result = (await info(
        flac(
          info: streamInfo(totalSamples: 44100),
          blocks: [
            (
              6,
              pictureStructure(
                image: utf8.encode('https://example.org/cover.jpg'),
                mimeType: '-->',
              ),
            ),
          ],
        ),
        withCover: true,
      ))!;
      expect(result.cover, isNull);
    });

    test('is none when the picture\'s lengths do not fit it', () async {
      final damaged = pictureStructure(image: jpegBytes())
        ..setRange(4, 8, be32(100000));
      final result = (await info(
        flac(info: streamInfo(totalSamples: 44100), blocks: [(6, damaged)]),
        withCover: true,
      ))!;
      expect(result.cover, isNull);
      expect(result.durationMs, 1000);
    });
  });

  group('files', () {
    test('may carry an ID3v2 tag before the marker', () async {
      final result = (await info([
        ...id3(3, frame3('TIT2', latin1.encode('Ignored'))),
        ...tagged(['TITLE=From the comments']),
      ]))!;
      expect(result.title, 'From the comments');
      expect(result.durationMs, 10000);
    });

    test('that are not FLAC are not read', () async {
      expect(await info(utf8.encode('Not a FLAC file at all.')), isNull);
      expect(await info(const []), isNull);
      expect(await info(id3(3, frame3('TIT2', latin1.encode('Tag')))), isNull);
    });

    test('are read only at their start, however large', () async {
      final head = tagged(['TITLE=A Chapter', 'ALBUM=A Book']);
      final source = SparseSource(1 << 30, {0: head});
      final result = (await readFlacInfo(source))!;
      expect(result.album, 'A Book');
      expect(source.bytesRead, lessThan(1024));
    });
  });

  group('damaged files are refused', () {
    Future<void> refused(List<int> bytes) =>
        expectLater(info(bytes), throwsA(isA<FormatException>()));

    test('when they end inside their metadata', () async {
      final whole = tagged(['TITLE=A Chapter']);
      await refused(whole.sublist(0, 20));
      await refused(whole.sublist(0, 4 + 4 + 34 + 2));
    });

    test('when a block runs past the end of the file', () async {
      final whole = tagged(['TITLE=A Chapter']);
      await refused(whole.sublist(0, whole.length - 256 - 3));
    });

    test('when they do not open with STREAMINFO', () async {
      await refused([
        ...ascii.encode('fLaC'),
        ...metadataBlock(4, vorbisComments(const [])),
        ...metadataBlock(0, streamInfo(totalSamples: 44100), last: true),
      ]);
    });

    test('when they have a second STREAMINFO', () async {
      await refused(
        flac(
          info: streamInfo(totalSamples: 44100),
          blocks: [(0, streamInfo(totalSamples: 44100))],
        ),
      );
    });

    test('when STREAMINFO gives no sample rate', () async {
      await refused(flac(info: streamInfo(sampleRate: 0, totalSamples: 1)));
    });

    test('when they claim more blocks than any real file has', () async {
      await refused([
        ...ascii.encode('fLaC'),
        ...metadataBlock(0, streamInfo(totalSamples: 44100)),
        for (var i = 0; i < 2000; i++) ...metadataBlock(1, const []),
      ]);
    });

    test('when their comments claim more than their block holds', () async {
      final comments = vorbisComments(['TITLE=A Chapter']);
      // The count, after the vendor string: far more comments than the block could hold.
      final vendorLength = ByteData.sublistView(Uint8List.fromList(comments))
          .getUint32(0, Endian.little);
      final tooMany = [...comments]
        ..setRange(4 + vendorLength, 8 + vendorLength, le32(1000000));
      await refused(
        flac(info: streamInfo(totalSamples: 44100), blocks: [(4, tooMany)]),
      );

      final tooLong = [...comments]
        ..setRange(8 + vendorLength, 12 + vendorLength, le32(5000));
      await refused(
        flac(info: streamInfo(totalSamples: 44100), blocks: [(4, tooLong)]),
      );

      final longVendor = [...comments]..setRange(0, 4, le32(1 << 30));
      await refused(
        flac(info: streamInfo(totalSamples: 44100), blocks: [(4, longVendor)]),
      );
    });
  });
}
