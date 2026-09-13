import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:test/test.dart';

// A minimal MP4 writer, so the reader can be tested against structures that real fixtures cannot
// cheaply provide: a file shaped like one over 4 GB, or a table that lies about its size.

List<int> u16(int v) => (ByteData(2)..setUint16(0, v)).buffer.asUint8List();
List<int> u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();
List<int> u64(int v) => (ByteData(8)..setUint64(0, v)).buffer.asUint8List();

List<int> box(String type, List<int> payload) => [
  ...u32(8 + payload.length),
  ...ascii.encode(type),
  ...payload,
];

/// A box whose size is given as a 64-bit `largesize`, as any box over 4 GB must be.
List<int> largeBox(String type, List<int> payload) => [
  ...u32(1),
  ...ascii.encode(type),
  ...u64(16 + payload.length),
  ...payload,
];

const fullBox = [0, 0, 0, 0];

List<int> textSample(String title) {
  final bytes = utf8.encode(title);
  return [...u16(bytes.length), ...bytes];
}

List<int> chplBox(List<(int, String)> chapters) {
  final payload = <int>[1, 0, 0, 0, 0, 0, 0, 0, chapters.length];
  for (final (ms, title) in chapters) {
    final bytes = utf8.encode(title);
    payload
      ..addAll(u64(ms * 10000))
      ..add(bytes.length)
      ..addAll(bytes);
  }
  return box('chpl', payload);
}

List<int> trackHeader(int id) => box('tkhd', [
  ...fullBox,
  ...u32(0),
  ...u32(0),
  ...u32(id),
  ...List.filled(68, 0),
]);

/// Builds an MP4 with the given chapters as a QuickTime chapter track, as a `chpl` atom, or both.
///
/// [bigFile] shapes it like a file over 4 GB: a `largesize` mdat and 64-bit chunk offsets.
/// [padding] adds bytes of audio payload after the chapter samples.
Uint8List mp4({
  List<(int, String)>? chapterTrack,
  List<(int, String)>? nero,
  bool bigFile = false,
  int padding = 0,
  int totalMs = 15000,
  int timescale = 1000,
}) {
  final ftyp = box('ftyp', [...ascii.encode('M4B '), ...u32(0)]);
  final samples = [
    for (final (_, title) in chapterTrack ?? const <(int, String)>[])
      textSample(title),
  ];
  final mdatPayload = [
    for (final sample in samples) ...sample,
    ...List.filled(padding, 0),
  ];
  final mdat = bigFile
      ? largeBox('mdat', mdatPayload)
      : box('mdat', mdatPayload);
  final firstSample = ftyp.length + (bigFile ? 16 : 8);

  final traks = <int>[
    ...box('trak', [
      ...trackHeader(1),
      if (chapterTrack != null) ...box('tref', box('chap', u32(2))),
    ]),
  ];

  if (chapterTrack != null) {
    final starts = [for (final (ms, _) in chapterTrack) ms];
    final durations = [
      for (var i = 0; i < starts.length; i++)
        ((i + 1 < starts.length ? starts[i + 1] : totalMs) - starts[i]) *
            timescale ~/
            1000,
    ];
    final stbl = box('stbl', [
      ...box('stts', [
        ...fullBox,
        ...u32(durations.length),
        for (final d in durations) ...[...u32(1), ...u32(d)],
      ]),
      ...box('stsz', [
        ...fullBox,
        ...u32(0),
        ...u32(samples.length),
        for (final s in samples) ...u32(s.length),
      ]),
      ...box('stsc', [
        ...fullBox,
        ...u32(1),
        ...u32(1),
        ...u32(samples.length),
        ...u32(1),
      ]),
      ...(bigFile
          ? box('co64', [...fullBox, ...u32(1), ...u64(firstSample)])
          : box('stco', [...fullBox, ...u32(1), ...u32(firstSample)])),
    ]);
    traks.addAll(
      box('trak', [
        ...trackHeader(2),
        ...box('mdia', [
          ...box('mdhd', [
            ...fullBox,
            ...u32(0),
            ...u32(0),
            ...u32(timescale),
            ...u32(totalMs * timescale ~/ 1000),
            0,
            0,
            0,
            0,
          ]),
          ...box('hdlr', [
            ...fullBox,
            ...u32(0),
            ...ascii.encode('text'),
            ...List.filled(13, 0),
          ]),
          ...box('minf', stbl),
        ]),
      ]),
    );
  }

  final moov = box('moov', [
    ...box('mvhd', List.filled(100, 0)),
    ...traks,
    if (nero != null) ...box('udta', chplBox(nero)),
  ]);
  return Uint8List.fromList([...ftyp, ...mdat, ...moov]);
}

int indexOfType(Uint8List bytes, String type) {
  final needle = ascii.encode(type);
  for (var i = 0; i + 4 <= bytes.length; i++) {
    if (bytes[i] == needle[0] &&
        bytes[i + 1] == needle[1] &&
        bytes[i + 2] == needle[2] &&
        bytes[i + 3] == needle[3]) {
      return i;
    }
  }
  throw StateError('no "$type" in fixture');
}

/// Counts the bytes a reader actually pulls from its source.
final class CountingSource implements ByteSource {
  CountingSource(this._inner);

  final ByteSource _inner;
  int bytesRead = 0;

  @override
  int get length => _inner.length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    final bytes = await _inner.read(offset, count);
    bytesRead += bytes.length;
    return bytes;
  }
}

const threeChapters = [
  (0, 'Chapter One'),
  (4000, 'Chapter Two'),
  (9000, 'Chapter Three'),
];

List<Mp4Chapter> asChapters(List<(int, String)> list) => [
  for (final (ms, title) in list) Mp4Chapter(startMs: ms, title: title),
];

Future<Mp4Chapters?> readFile(String name) async {
  final source = await FileByteSource.open(File('test/fixtures/$name'));
  try {
    return await readMp4Chapters(source);
  } finally {
    await source.close();
  }
}

void main() {
  group('generated fixtures from spike (d)', () {
    test('a file with both formats reads its chpl atom', () async {
      final result = await readFile('sample.m4b');
      expect(result!.format, Mp4ChapterFormat.nero);
      expect(result.chapters, asChapters(threeChapters));
    });

    test(
      'a file with only a chapter track, as Apple writes, still reads',
      () async {
        final result = await readFile('sample_no_chpl.m4b');
        expect(result!.format, Mp4ChapterFormat.quickTime);
        expect(result.chapters, asChapters(threeChapters));
      },
    );
  });

  group('formats', () {
    test('a QuickTime chapter track with 32-bit offsets', () async {
      final result = await readMp4Chapters(
        MemoryByteSource(mp4(chapterTrack: threeChapters)),
      );
      expect(result!.format, Mp4ChapterFormat.quickTime);
      expect(result.chapters, asChapters(threeChapters));
    });

    test(
      'a file shaped like one over 4 GB: largesize mdat and co64 offsets',
      () async {
        final result = await readMp4Chapters(
          MemoryByteSource(mp4(chapterTrack: threeChapters, bigFile: true)),
        );
        expect(result!.chapters, asChapters(threeChapters));
      },
    );

    test('a timescale other than milliseconds converts correctly', () async {
      final result = await readMp4Chapters(
        MemoryByteSource(mp4(chapterTrack: threeChapters, timescale: 44100)),
      );
      expect(result!.chapters, asChapters(threeChapters));
    });

    test('titles are UTF-8, not Latin-1', () async {
      const titles = [(0, 'Préface'), (5000, '第一章'), (9000, 'Épilogue — fin')];
      final nero = await readMp4Chapters(MemoryByteSource(mp4(nero: titles)));
      final track = await readMp4Chapters(
        MemoryByteSource(mp4(chapterTrack: titles)),
      );
      expect(nero!.chapters, asChapters(titles));
      expect(track!.chapters, asChapters(titles));
    });

    test('when both formats are present the chpl atom wins', () async {
      final result = await readMp4Chapters(
        MemoryByteSource(
          mp4(
            chapterTrack: const [(0, 'From the track')],
            nero: const [(0, 'From chpl')],
          ),
        ),
      );
      expect(result!.format, Mp4ChapterFormat.nero);
      expect(result.chapters.single.title, 'From chpl');
    });

    test('an empty chpl atom falls back to the chapter track', () async {
      final result = await readMp4Chapters(
        MemoryByteSource(mp4(chapterTrack: threeChapters, nero: const [])),
      );
      expect(result!.format, Mp4ChapterFormat.quickTime);
    });

    test(
      'a file with neither format has no chapters, which is not an error',
      () async {
        expect(await readMp4Chapters(MemoryByteSource(mp4())), isNull);
      },
    );

    test('bytes that are not an MP4 at all have no chapters', () async {
      expect(await readMp4Chapters(MemoryByteSource(Uint8List(3))), isNull);
    });
  });

  group('reads by seeking, never by loading', () {
    test('a real file costs a tiny fraction of its bytes', () async {
      final bytes = File('test/fixtures/sample_no_chpl.m4b').readAsBytesSync();
      final source = CountingSource(MemoryByteSource(bytes));
      await readMp4Chapters(source);
      expect(source.bytesRead, lessThan(bytes.length ~/ 20));
    });

    test('bytes read do not depend on how much audio the file holds', () async {
      final small = CountingSource(
        MemoryByteSource(mp4(chapterTrack: threeChapters, padding: 1024)),
      );
      final large = CountingSource(
        MemoryByteSource(
          mp4(chapterTrack: threeChapters, padding: 4 * 1024 * 1024),
        ),
      );
      await readMp4Chapters(small);
      await readMp4Chapters(large);
      expect(large.bytesRead, small.bytesRead);
    });
  });

  group('damaged files are reported, not read as chapterless', () {
    test('a box larger than its parent', () async {
      final bytes = mp4(chapterTrack: threeChapters);
      final moov = indexOfType(bytes, 'moov') - 4;
      ByteData.sublistView(bytes).setUint32(moov, bytes.length);
      expect(
        readMp4Chapters(MemoryByteSource(bytes)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a chpl atom declaring more chapters than it holds', () async {
      final bytes = mp4(nero: threeChapters);
      final count = indexOfType(bytes, 'chpl') + 4 + 8;
      bytes[count] = 9;
      expect(
        readMp4Chapters(MemoryByteSource(bytes)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a table claiming billions of chapters fails fast instead of allocating them', () async {
      final bytes = mp4(chapterTrack: threeChapters);
      final firstRunCount = indexOfType(bytes, 'stts') + 4 + 8;
      ByteData.sublistView(bytes).setUint32(firstRunCount, 0xFFFFFFFF);
      expect(
        readMp4Chapters(MemoryByteSource(bytes)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a chunk offset pointing past the end of the file', () async {
      final bytes = mp4(chapterTrack: threeChapters);
      final offset = indexOfType(bytes, 'stco') + 4 + 8;
      ByteData.sublistView(bytes).setUint32(offset, bytes.length + 100);
      expect(
        readMp4Chapters(MemoryByteSource(bytes)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a file cut off part-way through the movie box', () async {
      final bytes = mp4(chapterTrack: threeChapters);
      final truncated = Uint8List.sublistView(bytes, 0, bytes.length - 40);
      expect(
        readMp4Chapters(MemoryByteSource(truncated)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
