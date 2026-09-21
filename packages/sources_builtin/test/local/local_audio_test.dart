import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:test/test.dart';

import 'support/image_bytes.dart';
import 'support/mp3_bytes.dart';
import 'support/vorbis_bytes.dart';

Future<LocalAudioInfo?> read(
  List<int> bytes, {
  required String extension,
  bool withCover = false,
}) => readLocalAudioInfo(
  MemoryByteSource(Uint8List.fromList(bytes)),
  extension: extension,
  withCover: withCover,
);

/// An MP3 of 100 counted frames, with [frames] in its tag.
List<int> mp3(List<int> frames) => [
  ...id3(3, frames),
  ...xingFrame(100),
  ...audio(10),
];

/// A FLAC file of ten seconds carrying [comments].
List<int> flacFile(List<String> comments) => flac(
  info: streamInfo(totalSamples: 441000),
  blocks: [(4, vorbisComments(comments))],
);

/// An Ogg Opus file of a minute carrying [comments].
List<int> opusFile(List<String> comments) => oggFile(
  identification: opusHead(),
  comments: opusTags(comments),
  endGranule: 312 + 48000 * 60,
);

/// An Ogg Vorbis file of a minute carrying [comments].
List<int> vorbisFile(List<String> comments) => oggFile(
  identification: vorbisId(),
  comments: vorbisCommentHeader(comments),
  setup: vorbisSetup(),
  endGranule: 44100 * 60,
);

void main() {
  group('the reader is chosen by extension', () {
    test('mp3 reads an MP3', () async {
      final info = (await read(
        mp3(frame3('TALB', latin1.encode('A Book'))),
        extension: 'mp3',
      ))!;
      expect(info.format, LocalAudioFormat.mp3);
      expect(info.durationMs, counted(100));
      expect(info.durationIsEstimate, isFalse);
      expect(info.album, 'A Book');
    });

    test('flac reads a FLAC file, whatever the case', () async {
      final info = (await read(
        flacFile(['ALBUM=A Book', 'CHAPTER001=00:00:05.000']),
        extension: 'FLAC',
      ))!;
      expect(info.format, LocalAudioFormat.flac);
      expect(info.durationMs, 10000);
      expect(info.album, 'A Book');
      expect(info.chapters, const [
        EmbeddedChapter(startMs: 5000, title: 'Chapter 1'),
      ]);
    });

    test(
      'ogg, oga and opus read Ogg, telling the codec by the stream',
      () async {
        final vorbis = vorbisFile(const ['TITLE=Vorbis']);
        final opus = opusFile(const ['TITLE=Opus']);
        expect(
          (await read(vorbis, extension: 'ogg'))!.format,
          LocalAudioFormat.oggVorbis,
        );
        expect(
          (await read(opus, extension: 'ogg'))!.format,
          LocalAudioFormat.oggOpus,
        );
        expect(
          (await read(opus, extension: 'oga'))!.format,
          LocalAudioFormat.oggOpus,
        );
        final misnamed = (await read(vorbis, extension: 'opus'))!;
        expect(misnamed.format, LocalAudioFormat.oggVorbis);
        expect(misnamed.title, 'Vorbis');
        expect(misnamed.durationMs, 60000);
      },
    );

    test('anything else reads an MPEG-4 file, chapters included', () async {
      final bytes = await File('test/fixtures/sample.m4b').readAsBytes();
      final info = (await read(bytes, extension: 'm4b'))!;
      expect(info.format, LocalAudioFormat.mp4);
      expect(info.durationIsEstimate, isFalse);
      expect(info.chapters, const [
        EmbeddedChapter(startMs: 0, title: 'Chapter One'),
        EmbeddedChapter(startMs: 4000, title: 'Chapter Two'),
        EmbeddedChapter(startMs: 9000, title: 'Chapter Three'),
      ]);
    });

    test(
      'and a file that is not what its extension says is not read',
      () async {
        expect(await read(opusFile(const []), extension: 'flac'), isNull);
        expect(await read(flacFile(const []), extension: 'ogg'), isNull);
        expect(await read(mp3(const []), extension: 'opus'), isNull);
        expect(await read(utf8.encode('Not audio.'), extension: 'mp3'), isNull);
      },
    );

    test('and a damaged file is reported', () async {
      final whole = flacFile(const ['TITLE=A Chapter']);
      expect(
        read(whole.sublist(0, 30), extension: 'flac'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('the cover is read only when asked for', () async {
    final image = jpegBytes(fill: 0x71);
    final bytes = opusFile([pictureComment(image: image)]);
    expect((await read(bytes, extension: 'opus'))!.cover, isNull);
    final cover = (await read(
      bytes,
      extension: 'opus',
      withCover: true,
    ))!.cover;
    expect(cover!.bytes, image);
  });

  group('a file that is a book of its own', () {
    test('is titled by its album and credited to its album artist, as music is tagged', () async {
      final info = (await read(
        flacFile([
          'TITLE=Chapter One',
          'ALBUM=A Book',
          'ARTIST=A Performer',
          'ALBUMARTIST=An Author',
        ]),
        extension: 'flac',
      ))!;
      expect(info.bookTitle, 'A Book');
      expect(info.author, 'An Author');
    });

    test('falls back to its title and artist', () async {
      final info = (await read(
        vorbisFile(const ['TITLE=A Book', 'ARTIST=An Author']),
        extension: 'ogg',
      ))!;
      expect(info.bookTitle, 'A Book');
      expect(info.author, 'An Author');
    });

    test('in MPEG-4 is titled by its title, as audiobook taggers write it', () {
      const info = LocalAudioInfo(
        format: LocalAudioFormat.mp4,
        durationMs: 1000,
        durationIsEstimate: false,
        title: 'A Book',
        album: 'A Series',
        artist: 'An Author',
        albumArtist: 'A Publisher',
      );
      expect(info.bookTitle, 'A Book');
      expect(info.author, 'An Author');
    });
  });

  test('the extensions read include FLAC and Ogg', () {
    expect(
      audioExtensions,
      containsAll(['mp3', 'm4a', 'm4b', 'mp4', 'flac', 'ogg', 'oga', 'opus']),
    );
  });
}
