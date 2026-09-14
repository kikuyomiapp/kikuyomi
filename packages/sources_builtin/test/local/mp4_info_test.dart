import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:test/test.dart';

import 'support/image_bytes.dart';

List<int> u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();
List<int> u64(int v) => (ByteData(8)..setUint64(0, v)).buffer.asUint8List();

/// Latin-1, because tag item types start with the byte 0xA9, which is '©'.
List<int> box(String type, List<int> payload) => [
  ...u32(8 + payload.length),
  ...latin1.encode(type),
  ...payload,
];

List<int> movieHeader({
  required int version,
  required int timescale,
  required int duration,
}) => box(
  'mvhd',
  version == 1
      ? [1, 0, 0, 0, ...u64(0), ...u64(0), ...u32(timescale), ...u64(duration)]
      : [0, 0, 0, 0, ...u32(0), ...u32(0), ...u32(timescale), ...u32(duration)],
);

List<int> textItem(String type, String value) =>
    box(type, box('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(value)]));

/// A cover item holding a data box for each of [images], each with its type indicator: 13 is JPEG
/// and 14 PNG.
List<int> coverItem(List<(int, List<int>)> images) => box('covr', [
  for (final (kind, bytes) in images)
    ...box('data', [0, 0, 0, kind, 0, 0, 0, 0, ...bytes]),
]);

/// Type 0 is raw bytes, as `trkn` and `disk` store them: reserved(2) number(2) total(2), then a
/// further reserved(2).
List<int> numberItem(String type, int number, int total) => box(
  type,
  box('data', [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    number >> 8,
    number & 0xFF,
    total >> 8,
    total & 0xFF,
    0,
    0,
  ]),
);

Uint8List mp4({
  required List<int> header,
  List<int>? tagItems,
  bool isoMeta = true,
}) {
  final handler = box('hdlr', [
    0,
    0,
    0,
    0,
    ...u32(0),
    ...latin1.encode('mdir'),
    ...List.filled(13, 0),
  ]);
  final udta = tagItems == null
      ? const <int>[]
      : box(
          'udta',
          box('meta', [
            if (isoMeta) ...[0, 0, 0, 0],
            ...handler,
            ...box('ilst', tagItems),
          ]),
        );
  return Uint8List.fromList([
    ...box('ftyp', [...latin1.encode('M4B '), ...u32(0)]),
    ...box('moov', [...header, ...udta]),
  ]);
}

void main() {
  test('the ffmpeg-generated fixture: duration, tags and chapters', () async {
    final source = await FileByteSource.open(File('test/fixtures/sample.m4b'));
    try {
      final info = (await readMp4Info(source))!;
      expect(info.durationMs, closeTo(15000, 100));
      expect(info.title, 'Kikuyomi Spike Fixture');
      expect(info.artist, 'Generated Tone');
      expect(info.chapters!.chapters, hasLength(3));
    } finally {
      await source.close();
    }
  });

  group('duration', () {
    test('from a 32-bit movie header', () async {
      final info = await readMp4Info(
        MemoryByteSource(
          mp4(header: movieHeader(version: 0, timescale: 1000, duration: 5000)),
        ),
      );
      expect(info!.durationMs, 5000);
    });

    test('from a 64-bit movie header, in its own timescale', () async {
      final info = await readMp4Info(
        MemoryByteSource(
          mp4(
            header: movieHeader(
              version: 1,
              timescale: 44100,
              duration: 44100 * 7200,
            ),
          ),
        ),
      );
      expect(info!.durationMs, 7200 * 1000);
    });
  });

  group('tags', () {
    final items = [
      ...textItem('©nam', 'A Long Book'),
      ...textItem('©ART', 'An Author'),
      ...textItem('©alb', 'The Series'),
      ...textItem('©wrt', 'A Narrator'),
      ...coverItem([(13, jpegBytes())]),
    ];

    test('are read from ISO-style metadata', () async {
      final info = (await readMp4Info(
        MemoryByteSource(
          mp4(
            header: movieHeader(version: 0, timescale: 1000, duration: 1000),
            tagItems: items,
          ),
        ),
      ))!;
      expect(info.title, 'A Long Book');
      expect(info.artist, 'An Author');
      expect(info.album, 'The Series');
      expect(info.composer, 'A Narrator');
    });

    test('are read from QuickTime-style metadata too', () async {
      final info = (await readMp4Info(
        MemoryByteSource(
          mp4(
            header: movieHeader(version: 0, timescale: 1000, duration: 1000),
            tagItems: items,
            isoMeta: false,
          ),
        ),
      ))!;
      expect(info.title, 'A Long Book');
      expect(info.composer, 'A Narrator');
    });

    test('include the track and disc numbers and the album artist', () async {
      final info = (await readMp4Info(
        MemoryByteSource(
          mp4(
            header: movieHeader(version: 0, timescale: 1000, duration: 1000),
            tagItems: [
              ...textItem('aART', 'An Album Artist'),
              ...numberItem('trkn', 3, 12),
              ...numberItem('disk', 2, 2),
            ],
          ),
        ),
      ))!;
      expect(info.albumArtist, 'An Album Artist');
      expect(info.trackNumber, 3);
      expect(info.discNumber, 2);
    });

    test('are simply absent when a file has none', () async {
      final info = (await readMp4Info(
        MemoryByteSource(
          mp4(header: movieHeader(version: 0, timescale: 1000, duration: 1000)),
        ),
      ))!;
      expect(info.title, isNull);
      expect(info.artist, isNull);
      expect(info.chapters, isNull);
    });
  });

  group('cover', () {
    Future<Mp4Info> read(List<int> tagItems, {bool withCover = true}) async =>
        (await readMp4Info(
          MemoryByteSource(
            mp4(
              header: movieHeader(version: 0, timescale: 1000, duration: 1000),
              tagItems: tagItems,
            ),
          ),
          withCover: withCover,
        ))!;

    test('is not read unless asked for', () async {
      final info = await read([
        ...textItem('©nam', 'A Long Book'),
        ...coverItem([(13, jpegBytes())]),
      ], withCover: false);
      expect(info.title, 'A Long Book');
      expect(info.cover, isNull);
    });

    test('is read from a covr item holding a JPEG', () async {
      final image = jpegBytes(length: 500);
      final info = await read([
        ...textItem('©nam', 'A Long Book'),
        ...coverItem([(13, image)]),
        ...textItem('©ART', 'An Author'),
      ]);
      expect(info.cover!.mimeType, 'image/jpeg');
      expect(info.cover!.bytes, image);
      expect(info.title, 'A Long Book');
      expect(info.artist, 'An Author');
    });

    test('is read from a covr item holding a PNG', () async {
      final image = pngBytes();
      final info = await read(coverItem([(14, image)]));
      expect(info.cover!.mimeType, 'image/png');
      expect(info.cover!.bytes, image);
    });

    test('is the first image when the item holds several', () async {
      final first = pngBytes();
      final info = await read(coverItem([(14, first), (13, jpegBytes())]));
      expect(info.cover!.bytes, first);
    });

    test('is null when the file has no covr item', () async {
      final info = await read(textItem('©nam', 'A Long Book'));
      expect(info.cover, isNull);
    });
  });

  group('unusable files', () {
    test('bytes with no movie box are not an MP4', () async {
      expect(await readMp4Info(MemoryByteSource(Uint8List(3))), isNull);
    });

    test('a movie box with no header is reported', () async {
      final bytes = Uint8List.fromList([...box('moov', box('udta', const []))]);
      expect(
        readMp4Info(MemoryByteSource(bytes)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a zero timescale is reported rather than dividing by it', () async {
      expect(
        readMp4Info(
          MemoryByteSource(
            mp4(header: movieHeader(version: 0, timescale: 0, duration: 1000)),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
