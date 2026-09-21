import 'dart:convert';
import 'dart:io';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:test/test.dart';

import 'support/image_bytes.dart';
import 'support/mp3_bytes.dart';
import 'support/vorbis_bytes.dart';

/// An MP3 with [image] embedded as its front cover, or with no picture when [image] is null.
List<int> mp3({List<int>? image}) => [
  ...id3(3, [
    ...frame3('TALB', latin1.encode('A Book')),
    if (image != null)
      ...rawFrame3('APIC', apicBody(mimeType: 'image/jpeg', image: image)),
  ]),
  ...audio(20),
];

void main() {
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('kikuyomi_cover_');
  });

  tearDown(() => folder.delete(recursive: true));

  Future<File> put(String name, List<int> bytes) =>
      File('${folder.path}/$name').writeAsBytes(bytes);

  group('a local cover', () {
    test('is the picture embedded in the audio', () async {
      final image = jpegBytes(fill: 0x33);
      final cover = await readLocalCover(
        await put('book.mp3', mp3(image: image)),
      );
      expect(cover!.mimeType, 'image/jpeg');
      expect(cover.bytes, image);
    });

    test('is the image beside the audio before the embedded one', () async {
      final image = pngBytes(fill: 0x44);
      final cover = await readLocalCover(
        await put('01.mp3', mp3(image: jpegBytes())),
        image: await put('cover.png', image),
      );
      expect(cover!.mimeType, 'image/png');
      expect(cover.bytes, image);
    });

    test(
      'is the embedded picture when the image beside it is not an image',
      () async {
        final cover = await readLocalCover(
          await put('01.mp3', mp3(image: jpegBytes())),
          image: await put('cover.jpg', utf8.encode('Not an image.')),
        );
        expect(cover!.mimeType, 'image/jpeg');
      },
    );

    test('is the embedded picture when the image beside it has gone', () async {
      final cover = await readLocalCover(
        await put('01.mp3', mp3(image: jpegBytes())),
        image: File('${folder.path}/cover.jpg'),
      );
      expect(cover!.mimeType, 'image/jpeg');
    });

    test('is the picture in a FLAC file', () async {
      final image = pngBytes(fill: 0x36);
      final cover = await readLocalCover(
        await put(
          'book.flac',
          flac(
            info: streamInfo(totalSamples: 44100),
            blocks: [
              (6, pictureStructure(image: image, mimeType: 'image/png')),
            ],
          ),
        ),
      );
      expect(cover!.mimeType, 'image/png');
      expect(cover.bytes, image);
    });

    test('is the picture in an Ogg file', () async {
      final image = jpegBytes(fill: 0x37);
      final cover = await readLocalCover(
        await put(
          'book.opus',
          oggFile(
            identification: opusHead(),
            comments: opusTags([pictureComment(image: image)]),
            endGranule: 48000 * 10,
          ),
        ),
      );
      expect(cover!.bytes, image);
    });

    test('is null for an Ogg file that cannot be timed', () async {
      final file = await put('book.ogg', [
        ...oggFile(
          identification: opusHead(),
          comments: opusTags([pictureComment(image: jpegBytes())]),
          endGranule: 48000 * 10,
        ),
        ...oggFile(
          identification: opusHead(),
          comments: opusTags(const []),
          endGranule: 48000 * 10,
          serial: 7,
        ),
      ]);
      expect(await readLocalCover(file), isNull);
    });

    test('is null for audio with no picture', () async {
      expect(await readLocalCover(await put('book.mp3', mp3())), isNull);
    });

    test('is null for a file that is not audio after all', () async {
      final file = await put('book.m4b', utf8.encode('Not an audiobook.'));
      expect(await readLocalCover(file), isNull);
    });

    test('cannot be read from audio that is missing', () async {
      expect(
        readLocalCover(File('${folder.path}/gone.mp3')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group("a folder's cover image", () {
    test('is found by name, as a folder book finds it', () async {
      await put('01.mp3', mp3());
      await put('back.jpg', jpegBytes());
      await put('Cover.png', pngBytes());

      final image = await findFolderCoverImage(folder);
      expect(image!.uri.pathSegments.last, 'Cover.png');
      expect(await image.readAsBytes(), pngBytes());
    });

    test('is not found among images with none named as a cover', () async {
      await put('01.mp3', mp3());
      await put('back.jpg', jpegBytes());
      await put('disc.png', pngBytes());
      expect(await findFolderCoverImage(folder), isNull);
    });
  });
}
