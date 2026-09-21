import 'dart:convert';
import 'dart:typed_data';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:test/test.dart';

import 'support/image_bytes.dart';
import 'support/sparse_source.dart';
import 'support/vorbis_bytes.dart';

Future<OggInfo?> info(List<int> bytes, {bool withCover = false}) => readOggInfo(
  MemoryByteSource(Uint8List.fromList(bytes)),
  withCover: withCover,
);

/// An Ogg Vorbis file at 44.1 kHz carrying [comments], whose last page ends at [endGranule].
List<int> vorbisFile(
  List<String> comments, {
  int endGranule = 44100 * 60,
  int maxSegments = 255,
  int serial = 0x4B494B55,
}) => oggFile(
  identification: vorbisId(),
  comments: vorbisCommentHeader(comments),
  setup: vorbisSetup(),
  endGranule: endGranule,
  maxSegments: maxSegments,
  serial: serial,
);

/// An Ogg Opus file with a pre-skip of [preSkip], whose last page ends at [endGranule].
List<int> opusFile(
  List<String> comments, {
  int preSkip = 312,
  int endGranule = 48000 * 60 + 312,
  int maxSegments = 255,
}) => oggFile(
  identification: opusHead(preSkip: preSkip),
  comments: opusTags(comments),
  endGranule: endGranule,
  maxSegments: maxSegments,
);

void main() {
  group('Vorbis', () {
    test('is timed by its last page, at its own sample rate', () async {
      final result = (await info(
        vorbisFile(const [], endGranule: 44100 * 75 + 441),
      ))!;
      expect(result.codec, OggCodec.vorbis);
      expect(result.durationMs, 75010);
    });

    test('is timed at any sample rate its header states', () async {
      final result = (await info(
        oggFile(
          identification: vorbisId(sampleRate: 22050),
          comments: vorbisCommentHeader(const []),
          setup: vorbisSetup(),
          endGranule: 22050 * 30,
        ),
      ))!;
      expect(result.durationMs, 30000);
    });

    test('has its tags read from its comment header', () async {
      final result = (await info(
        vorbisFile([
          'TITLE=Chapter 3',
          'ARTIST=An Author',
          'ALBUMARTIST=An Album Artist',
          'ALBUM=Ōkami',
          'COMPOSER=A Narrator',
          'TRACKNUMBER=3/12',
          'DISCNUMBER=1/2',
        ]),
      ))!;
      expect(result.title, 'Chapter 3');
      expect(result.artist, 'An Author');
      expect(result.albumArtist, 'An Album Artist');
      expect(result.album, 'Ōkami');
      expect(result.composer, 'A Narrator');
      expect(result.trackNumber, 3);
      expect(result.discNumber, 1);
    });
  });

  group('Opus', () {
    test('is timed at 48 kHz, less its pre-skip', () async {
      final result = (await info(
        opusFile(const [], preSkip: 312, endGranule: 48000 * 60 + 312),
      ))!;
      expect(result.codec, OggCodec.opus);
      expect(result.durationMs, 60000);
    });

    test('is timed at 48 kHz whatever rate its audio was made at', () async {
      final result = (await info(
        oggFile(
          identification: opusHead(preSkip: 3840, inputSampleRate: 16000),
          comments: opusTags(const []),
          endGranule: 3840 + 48000 * 90 + 24000,
        ),
      ))!;
      expect(result.durationMs, 90500);
    });

    test('has its tags and chapters read from its comment header', () async {
      final result = (await info(
        opusFile([
          'ALBUM=A Book',
          'ARTIST=An Author',
          'CHAPTER001=00:00:00.000',
          'CHAPTER001NAME=Opening',
          'CHAPTER002=00:30:00.250',
          'CHAPTER002NAME=Closing',
        ]),
      ))!;
      expect(result.album, 'A Book');
      expect(result.artist, 'An Author');
      expect(result.chapters, const [
        EmbeddedChapter(startMs: 0, title: 'Opening'),
        EmbeddedChapter(startMs: 1800250, title: 'Closing'),
      ]);
    });
  });

  group('a comment header', () {
    test('spread over many pages is read whole', () async {
      final comments = [
        'TITLE=A Chapter',
        'DESCRIPTION=${'A long description. ' * 100}',
        'ALBUM=A Book',
        for (var i = 1; i <= 40; i++) ...[
          'CHAPTER${'$i'.padLeft(3, '0')}=00:${'$i'.padLeft(2, '0')}:00.000',
          'CHAPTER${'$i'.padLeft(3, '0')}NAME=Part $i',
        ],
      ];
      // Two lacing values to a page spread the header over a page for every 510 bytes.
      final bytes = vorbisFile(comments, maxSegments: 2);
      final result = (await info(bytes))!;
      expect(result.title, 'A Chapter');
      expect(result.album, 'A Book');
      expect(result.chapters, hasLength(40));
      expect(
        result.chapters.last,
        const EmbeddedChapter(startMs: 2400000, title: 'Part 40'),
      );
      expect(result.durationMs, 60000);
    });

    test('holding a picture over many pages gives the cover', () async {
      final image = jpegBytes(length: 200 * 1024, fill: 0x42);
      final result = (await info(
        opusFile(['TITLE=A Chapter', pictureComment(image: image)]),
        withCover: true,
      ))!;
      expect(result.title, 'A Chapter');
      expect(result.cover!.mimeType, 'image/jpeg');
      expect(result.cover!.bytes, image);
    });

    test('gives no cover unless one is asked for', () async {
      final result = (await info(
        opusFile([pictureComment(image: jpegBytes())]),
      ))!;
      expect(result.cover, isNull);
    });

    test('gives the picture marked as the front cover', () async {
      final front = pngBytes(fill: 0x46);
      final result = (await info(
        vorbisFile([
          pictureComment(image: jpegBytes(), type: 4),
          pictureComment(image: front, mimeType: 'image/png'),
        ]),
        withCover: true,
      ))!;
      expect(result.cover!.bytes, front);
    });

    test('gives no cover for a picture that is not base64', () async {
      final result = (await info(
        vorbisFile(['METADATA_BLOCK_PICTURE=not base64 at all!']),
        withCover: true,
      ))!;
      expect(result.cover, isNull);
      expect(result.durationMs, 60000);
    });
  });

  group('the end of the stream', () {
    test('is the last whole page when the file is cut short', () async {
      final whole = vorbisFile(const [], endGranule: 44100 * 60);
      // Three audio pages of 228 bytes end at 20, 40 and 60 seconds; cut into the last.
      final cut = whole.sublist(0, whole.length - 100);
      expect((await info(cut))!.durationMs, 40000);
    });

    test('passes over a last page on which no packet ends', () async {
      final result = (await info([
        ...vorbisFile(const [], endGranule: 44100 * 60),
        // A packet begun and not finished: its page has no granule position.
        ...oggPage(
          lacing: const [255],
          body: List.filled(255, 9),
          sequence: 9,
          granule: -1,
        ),
      ]))!;
      expect(result.durationMs, 60000);
    });

    test('is found reading little of a large file', () async {
      final head = opusFile(const ['TITLE=A Chapter']);
      final last = oggPage(
        lacing: const [100],
        body: List.filled(100, 3),
        sequence: 5000,
        granule: 312 + 48000 * 3600 * 10,
        endsStream: true,
      );
      const length = 1 << 30;
      final source = SparseSource(length, {
        0: head,
        length - last.length: last,
      });
      final result = (await readOggInfo(source))!;
      expect(result.durationMs, 3600 * 10 * 1000);
      expect(source.bytesRead, lessThan(256 * 1024));
    });
  });

  group('files that are not Ogg Vorbis or Opus', () {
    test('are not read', () async {
      expect(await info(utf8.encode('Not an Ogg file at all.')), isNull);
      expect(await info(const []), isNull);
    });

    test('are not read when their stream is in another codec', () async {
      final speex = oggFile(
        identification: [...ascii.encode('Speex   '), ...List.filled(72, 0)],
        comments: vorbisComments(const []),
        endGranule: 16000,
      );
      expect(await info(speex), isNull);
    });
  });

  group('files are refused', () {
    Future<void> refused(List<int> bytes, [Pattern? message]) => expectLater(
      info(bytes),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          message == null ? anything : contains(message),
        ),
      ),
    );

    test('when they chain one stream after another', () async {
      await refused([
        ...opusFile(const ['TITLE=Part One']),
        ...oggFile(
          identification: opusHead(),
          comments: opusTags(const ['TITLE=Part Two']),
          endGranule: 48000 * 30,
          serial: 0x0BADCAFE,
        ),
      ], 'chained');
    });

    test('when they multiplex streams together', () async {
      final first = packetPages(opusHead(), beginsStream: true).single;
      final other = packetPages(
        vorbisId(),
        serial: 0x0BADCAFE,
        beginsStream: true,
      ).single;
      final rest = opusFile(const []).sublist(first.length);
      await refused([...first, ...other, ...rest], 'multiplexed');
    });

    test('when their first page fails its checksum', () async {
      final bytes = opusFile(const []);
      // A byte of the header's output gain, past the magic that names the codec.
      bytes[44] ^= 0x01;
      await refused(bytes, 'checksum');
    });

    test('when the identification header does not stand alone', () async {
      final both = [...opusHead(), ...opusTags(const [])];
      final page = oggPage(
        lacing: [opusHead().length, opusTags(const []).length],
        body: both,
        beginsStream: true,
      );
      await refused(page);
    });

    test('when the identification header is not valid', () async {
      await refused(
        oggFile(
          identification: vorbisId(sampleRate: 0),
          comments: vorbisCommentHeader(const []),
          endGranule: 44100,
        ),
      );
    });

    test('when they end inside their comment header', () async {
      final whole = vorbisFile([
        'TITLE=A Chapter',
        'DESCRIPTION=${'x' * 2000}',
      ], maxSegments: 1);
      // The first page of 58 bytes, then pages of 283 bytes, the second of them cut short.
      await refused(whole.sublist(0, 58 + 283 + 100));
    });

    test('when the second packet is not a comment header', () async {
      await refused(
        oggFile(
          identification: opusHead(),
          comments: [...ascii.encode('OpusTagz'), ...vorbisComments(const [])],
          endGranule: 48000,
        ),
        'comment header',
      );
    });

    test('when a comment claims more than the header holds', () async {
      final comments = [
        ...opusTags(const ['TITLE=A Chapter']),
      ];
      // The comment's length, after the magic, the vendor string and the count.
      final vendorLength = ByteData.sublistView(Uint8List.fromList(comments))
          .getUint32(8, Endian.little);
      comments.setRange(16 + vendorLength, 20 + vendorLength, le32(1 << 20));
      await refused(
        oggFile(
          identification: opusHead(),
          comments: comments,
          endGranule: 48000,
        ),
      );
    });

    test(
      'when the comment header runs on over more pages than any real one',
      () async {
        // Pages of one full segment each, none of which ends the packet.
        final bytes = [
          ...packetPages(opusHead(), beginsStream: true).single,
          for (var i = 0; i < 5000; i++)
            ...oggPage(
              lacing: const [255],
              body: i == 0
                  ? [...ascii.encode('OpusTags'), ...List.filled(247, 0)]
                  : List.filled(255, 0),
              sequence: i + 1,
              granule: -1,
              continued: i > 0,
            ),
        ];
        await refused(bytes, 'pages');
      },
    );

    test('when they hold no audio', () async {
      final headersOnly = [
        ...packetPages(opusHead(), beginsStream: true).single,
        ...packetPages(opusTags(const []), sequence: 1).single,
      ];
      await refused(headersOnly, 'no audio');
    });

    test('when no page near the end says where the stream ends', () async {
      final bytes = [...opusFile(const []), ...List.filled(200 * 1024, 0x11)];
      await refused(bytes, 'says where');
    });
  });
}
