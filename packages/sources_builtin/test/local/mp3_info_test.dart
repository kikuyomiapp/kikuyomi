import 'dart:convert';
import 'dart:typed_data';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:test/test.dart';

import 'support/mp3_bytes.dart';

Future<Mp3Info?> info(List<int> bytes) =>
    readMp3Info(MemoryByteSource(Uint8List.fromList(bytes)));

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
