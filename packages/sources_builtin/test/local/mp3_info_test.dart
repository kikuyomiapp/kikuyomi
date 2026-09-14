import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:test/test.dart';

import 'support/image_bytes.dart';
import 'support/mp3_bytes.dart';

Future<Mp3Info?> info(List<int> bytes) =>
    readMp3Info(MemoryByteSource(Uint8List.fromList(bytes)));

/// The cover of an MP3 made of [tag] and some audio, read with the cover asked for.
Future<EmbeddedPicture?> coverOf(List<int> tag) async {
  final result = await readMp3Info(
    MemoryByteSource(Uint8List.fromList([...tag, ...audio(10)])),
    withCover: true,
  );
  return result!.cover;
}

/// A file of [length] bytes, zero except where [parts] put bytes at their offsets, so that a test
/// can shape a file far larger than the memory it takes. Counts the bytes read from it.
final class SparseSource implements ByteSource {
  SparseSource(this.length, this.parts);

  @override
  final int length;
  final Map<int, List<int>> parts;
  int bytesRead = 0;

  @override
  Future<Uint8List> read(int offset, int count) async {
    final end = math.min(offset + count, length);
    final bytes = Uint8List(math.max(end - offset, 0));
    for (final MapEntry(key: start, value: part) in parts.entries) {
      final to = math.min(start + part.length, end);
      for (var i = math.max(start, offset); i < to; i++) {
        bytes[i - offset] = part[i - start];
      }
    }
    bytesRead += bytes.length;
    return bytes;
  }
}

void main() {
  group('duration', () {
    test('is counted from a Xing header', () async {
      final result = (await info([...xingFrame(1000), ...audio(20)]))!;
      expect(result.durationMs, counted(1000));
      expect(result.durationIsEstimate, isFalse);
    });

    test('is counted from the Info header of a constant bitrate', () async {
      final result = (await info([
        ...xingFrame(50, id: 'Info'),
        ...audio(49),
      ]))!;
      expect(result.durationMs, counted(50));
      expect(result.durationIsEstimate, isFalse);
    });

    test('is counted from a VBRI header', () async {
      final result = (await info([...vbriFrame(500), ...audio(20)]))!;
      expect(result.durationMs, counted(500));
      expect(result.durationIsEstimate, isFalse);
    });

    test('is estimated from the bitrate when nothing counts frames', () async {
      final result = (await info(audio(100)))!;
      expect(result.durationMs, estimated(100));
      expect(result.durationIsEstimate, isTrue);
    });

    test('leaves the tags at either end out of the estimate', () async {
      final result = (await info([
        ...id3(3, frame3('TIT2', latin1.encode('A Chapter'))),
        ...audio(100),
        ...id3v1(title: 'x', artist: 'y', album: 'z', track: 1),
      ]))!;
      expect(result.durationMs, estimated(100));
    });
  });

  group('tags', () {
    test('are read from an ID3v2.3 tag', () async {
      final result = (await info([
        ...id3(3, [
          ...frame3('TIT2', latin1.encode('Chapter 3')),
          ...frame3('TPE1', latin1.encode('An Author')),
          ...frame3('TPE2', latin1.encode('An Album Artist')),
          ...frame3('TALB', latin1.encode('A Book')),
          ...frame3('TCOM', latin1.encode('A Narrator')),
          ...frame3('TRCK', latin1.encode('3/12')),
          ...frame3('TPOS', latin1.encode('2/2')),
        ]),
        ...audio(10),
      ]))!;
      expect(result.title, 'Chapter 3');
      expect(result.artist, 'An Author');
      expect(result.albumArtist, 'An Album Artist');
      expect(result.album, 'A Book');
      expect(result.composer, 'A Narrator');
      expect(result.trackNumber, 3);
      expect(result.discNumber, 2);
    });

    test('are read from an ID3v2.4 tag in UTF-8', () async {
      final result = (await info([
        ...id3(4, [
          ...frame4('TIT2', 'Café chapter'),
          ...frame4('TALB', 'Ōkami'),
        ]),
        ...audio(10),
      ]))!;
      expect(result.title, 'Café chapter');
      expect(result.album, 'Ōkami');
    });

    test('are read in UTF-16 with a byte order mark', () async {
      final result = (await info([
        ...id3(
          3,
          frame3('TIT2', [0xFF, 0xFE, 0x48, 0, 0x69, 0, 0, 0], encoding: 1),
        ),
        ...audio(10),
      ]))!;
      expect(result.title, 'Hi');
    });

    test('are read from an ID3v2.2 tag', () async {
      final result = (await info([
        ...id3(2, [
          ...frame2('TT2', 'Old Chapter'),
          ...frame2('TP1', 'Old Author'),
          ...frame2('TRK', '7'),
        ]),
        ...audio(10),
      ]))!;
      expect(result.title, 'Old Chapter');
      expect(result.artist, 'Old Author');
      expect(result.trackNumber, 7);
    });

    test('fall back to an ID3v1 tag', () async {
      final result = (await info([
        ...audio(10),
        ...id3v1(
          title: 'Short Title',
          artist: 'An Author',
          album: 'A Book',
          track: 4,
        ),
      ]))!;
      expect(result.title, 'Short Title');
      expect(result.artist, 'An Author');
      expect(result.album, 'A Book');
      expect(result.trackNumber, 4);
    });

    test('are simply absent when a file has none', () async {
      final result = (await info(audio(10)))!;
      expect(result.title, isNull);
      expect(result.album, isNull);
      expect(result.trackNumber, isNull);
    });
  });

  group('cover', () {
    test('is not read unless asked for', () async {
      final result = (await info([
        ...id3(3, [
          ...frame3('TIT2', latin1.encode('Chapter 1')),
          ...rawFrame3(
            'APIC',
            apicBody(mimeType: 'image/jpeg', image: jpegBytes()),
          ),
        ]),
        ...audio(10),
      ]))!;
      expect(result.title, 'Chapter 1');
      expect(result.cover, isNull);
    });

    test('is read from ID3v2.3 with a Latin-1 description', () async {
      final image = jpegBytes(length: 300);
      final cover = (await coverOf(
        id3(
          3,
          rawFrame3(
            'APIC',
            apicBody(
              mimeType: 'image/jpeg',
              image: image,
              description: latin1.encode('Front côver'),
            ),
          ),
        ),
      ))!;
      expect(cover.mimeType, 'image/jpeg');
      expect(cover.bytes, image);
    });

    test('is read from ID3v2.3 with a UTF-16 description', () async {
      final image = pngBytes();
      final cover = (await coverOf(
        id3(
          3,
          rawFrame3(
            'APIC',
            apicBody(
              mimeType: 'image/png',
              image: image,
              encoding: 1,
              // A byte order mark, then "AĀ" little-endian: 41 00 00 01. The zero bytes in the
              // middle belong to two characters, so they do not end the description.
              description: [0xFF, 0xFE, 0x41, 0x00, 0x00, 0x01],
            ),
          ),
        ),
      ))!;
      expect(cover.mimeType, 'image/png');
      expect(cover.bytes, image);
    });

    test('is read from ID3v2.4 with a Latin-1 description', () async {
      // Larger than 127 bytes, so the frame's syncsafe size takes more than one byte.
      final image = jpegBytes(length: 1000);
      final cover = (await coverOf(
        id3(
          4,
          rawFrame4(
            'APIC',
            apicBody(
              mimeType: 'image/jpeg',
              image: image,
              description: latin1.encode('Cover'),
            ),
          ),
        ),
      ))!;
      expect(cover.mimeType, 'image/jpeg');
      expect(cover.bytes, image);
    });

    test('is read from ID3v2.4 with a UTF-16 description', () async {
      final image = jpegBytes();
      final cover = (await coverOf(
        id3(
          4,
          rawFrame4(
            'APIC',
            apicBody(
              mimeType: 'image/jpeg',
              image: image,
              // Encoding 2 is big-endian UTF-16 with no byte order mark. "ĀA" is 01 00 00 41.
              encoding: 2,
              description: [0x01, 0x00, 0x00, 0x41],
            ),
          ),
        ),
      ))!;
      expect(cover.bytes, image);
    });

    test('is the front cover, even when another picture comes first', () async {
      final front = jpegBytes();
      final cover = (await coverOf(
        id3(3, [
          ...rawFrame3(
            'APIC',
            apicBody(mimeType: 'image/png', image: pngBytes(), pictureType: 4),
          ),
          ...rawFrame3('APIC', apicBody(mimeType: 'image/jpeg', image: front)),
        ]),
      ))!;
      expect(cover.bytes, front);
    });

    test('is the first picture when none is the front cover', () async {
      final first = pngBytes();
      final cover = (await coverOf(
        id3(3, [
          ...rawFrame3(
            'APIC',
            apicBody(mimeType: 'image/png', image: first, pictureType: 0),
          ),
          ...rawFrame3(
            'APIC',
            apicBody(
              mimeType: 'image/jpeg',
              image: jpegBytes(),
              pictureType: 4,
            ),
          ),
        ]),
      ))!;
      expect(cover.bytes, first);
    });

    test('is read from an ID3v2.2 PIC frame', () async {
      final image = pngBytes();
      final cover = (await coverOf(
        id3(2, [
          ...frame2('TT2', 'Old Chapter'),
          ...rawFrame2(
            'PIC',
            picBody(
              format: 'PNG',
              image: image,
              description: latin1.encode('Cover'),
            ),
          ),
        ]),
      ))!;
      expect(cover.mimeType, 'image/png');
      expect(cover.bytes, image);
    });

    test('takes its type from the image before the tag, and from the tag when the image does not say', () async {
      final png = await coverOf(
        id3(
          3,
          rawFrame3('APIC', apicBody(mimeType: 'image/jpg', image: pngBytes())),
        ),
      );
      // "BM" opens a BMP, a signature too short to be worth trusting.
      final bmp = await coverOf(
        id3(
          2,
          rawFrame2(
            'PIC',
            picBody(format: 'BMP', image: [0x42, 0x4D, ...List.filled(30, 0)]),
          ),
        ),
      );
      expect(png!.mimeType, 'image/png');
      expect(bmp!.mimeType, 'image/bmp');
    });

    test(
      'is found past the bytes that grouping and a data length add to a frame',
      () async {
        final image = jpegBytes();
        final body = apicBody(mimeType: 'image/jpeg', image: image);
        // In 2.3 grouping, 0x20, adds a group byte. In 2.4 grouping, 0x40, adds one, and a data
        // length indicator, 0x01, four more after it.
        final v3 = await coverOf(
          id3(3, rawFrame3('APIC', [7, ...body], format: 0x20)),
        );
        final v4 = await coverOf(
          id3(
            4,
            rawFrame4('APIC', [
              7,
              ...syncsafe(body.length),
              ...body,
            ], format: 0x41),
          ),
        );
        expect(v3!.bytes, image);
        expect(v4!.bytes, image);
      },
    );

    test('passes over a compressed picture for the next one', () async {
      final next = pngBytes();
      final cover = (await coverOf(
        id3(3, [
          // Compression, 0x80, puts the decompressed size before the body.
          ...rawFrame3('APIC', [
            ...u32(80),
            ...apicBody(mimeType: 'image/jpeg', image: jpegBytes()),
          ], format: 0x80),
          ...rawFrame3(
            'APIC',
            apicBody(mimeType: 'image/png', image: next, pictureType: 0),
          ),
        ]),
      ))!;
      expect(cover.bytes, next);
    });

    test('is null when the tag has no picture, or there is no tag', () async {
      expect(
        await coverOf(id3(3, frame3('TIT2', latin1.encode('Chapter 1')))),
        isNull,
      );
      expect(await coverOf(const []), isNull);
    });

    test(
      'is null when the frame links to an image instead of holding one',
      () async {
        expect(
          await coverOf(
            id3(
              3,
              rawFrame3(
                'APIC',
                apicBody(mimeType: '-->', image: ascii.encode('cover.jpg')),
              ),
            ),
          ),
          isNull,
        );
      },
    );

    test('is skipped unread when it claims more than 16 MB', () async {
      const claimed = 16 * 1024 * 1024 + 1;
      final frameHeader = [...ascii.encode('APIC'), ...u32(claimed), 0, 0];
      final tagSize = frameHeader.length + claimed + 32;
      final audioStart = 10 + tagSize;
      final audioBytes = audio(10);
      final source = SparseSource(audioStart + audioBytes.length, {
        0: [
          ...ascii.encode('ID3'),
          3,
          0,
          0,
          ...syncsafe(tagSize),
          ...frameHeader,
          ...apicBody(mimeType: 'image/jpeg', image: jpegBytes()),
        ],
        audioStart: audioBytes,
      });

      final result = (await readMp3Info(source, withCover: true))!;
      expect(result.cover, isNull);
      expect(result.durationMs, estimated(10));
      expect(source.bytesRead, lessThan(1024 * 1024));
    });
  });

  group('files that are not MP3s', () {
    test('bytes with no audio frames in them', () async {
      expect(await info(List.filled(4096, 0)), isNull);
    });

    test('a stray sync pattern before the audio is passed over', () async {
      final result = (await info([
        0xFF,
        0xFB,
        0x90,
        0x00,
        ...List.filled(10, 0x11),
        ...audio(100),
      ]))!;
      expect(result.durationMs, estimated(100));
    });
  });
}
