import 'dart:convert';
import 'dart:io';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:test/test.dart';

import 'support/mp3_bytes.dart';

/// An MP3 carrying whichever tags are given.
List<int> mp3({
  String? title,
  String? album,
  String? artist,
  String? albumArtist,
  String? composer,
  String? track,
  int frames = 20,
}) => [
  ...id3(3, [
    if (title != null) ...frame3('TIT2', latin1.encode(title)),
    if (album != null) ...frame3('TALB', latin1.encode(album)),
    if (artist != null) ...frame3('TPE1', latin1.encode(artist)),
    if (albumArtist != null) ...frame3('TPE2', latin1.encode(albumArtist)),
    if (composer != null) ...frame3('TCOM', latin1.encode(composer)),
    if (track != null) ...frame3('TRCK', latin1.encode(track)),
  ]),
  ...audio(frames),
];

void main() {
  late Directory root;
  late Directory folder;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kikuyomi_folder_');
    folder = await Directory('${root.path}/The Folder Name').create();
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> put(String name, List<int> bytes) =>
      File('${folder.path}/$name').writeAsBytes(bytes);

  Future<FolderBook> read() async => (await readFolderBook(folder))!;

  List<String> names(FolderBook book) => [
    for (final track in book.tracks) track.fileName,
  ];

  List<String> titles(FolderBook book) => [
    for (final track in book.tracks) track.title,
  ];

  group('order', () {
    test('follows the track numbers when every file has its own', () async {
      await put('z.mp3', mp3(title: 'Opening', track: '1'));
      await put('a.mp3', mp3(title: 'Middle', track: '2/3'));
      await put('m.mp3', mp3(title: 'End', track: '3'));

      final book = await read();
      expect(names(book), ['z.mp3', 'a.mp3', 'm.mp3']);
      expect(titles(book), ['Opening', 'Middle', 'End']);
    });

    test('follows the file names, naturally, when numbers repeat', () async {
      await put('Chapter 10.mp3', mp3(track: '1'));
      await put('Chapter 2.mp3', mp3(track: '1'));
      await put('Chapter 1.mp3', mp3(track: '1'));

      expect(names(await read()), [
        'Chapter 1.mp3',
        'Chapter 2.mp3',
        'Chapter 10.mp3',
      ]);
    });

    test('follows the file names when some files have no number', () async {
      await put('02 Two.mp3', mp3(track: '1'));
      await put('01 One.mp3', mp3());

      expect(names(await read()), ['01 One.mp3', '02 Two.mp3']);
    });
  });

  group('names', () {
    test('the book from its album tag, with author and narrator', () async {
      await put(
        '1.mp3',
        mp3(album: 'A Book', albumArtist: 'An Author', composer: 'A Narrator'),
      );
      await put(
        '2.mp3',
        mp3(album: 'A Book', albumArtist: 'An Author', composer: 'A Narrator'),
      );

      final book = await read();
      expect(book.title, 'A Book');
      expect(book.authors, ['An Author']);
      expect(book.narrators, ['A Narrator']);
    });

    test('the author from the artist when no album artist is set', () async {
      await put('1.mp3', mp3(artist: 'An Author'));
      expect((await read()).authors, ['An Author']);
    });

    test('the book from its folder, and chapters from file names', () async {
      await put('Part One.mp3', mp3());
      await put('Part Two.mp3', mp3());

      final book = await read();
      expect(book.title, 'The Folder Name');
      expect(book.authors, isEmpty);
      expect(titles(book), ['Part One', 'Part Two']);
    });

    test('a title every file shares does not name a chapter', () async {
      await put('Part One.mp3', mp3(title: 'A Book'));
      await put('Part Two.mp3', mp3(title: 'A Book'));
      expect(titles(await read()), ['Part One', 'Part Two']);
    });
  });

  test('carries each track\'s duration, and whether it is estimated', () async {
    await put('1.mp3', [...xingFrame(1000), ...audio(20)]);
    await put('2.mp3', mp3(frames: 100));

    final tracks = (await read()).tracks;
    expect(tracks[0].durationMs, counted(1000));
    expect(tracks[0].durationIsEstimate, isFalse);
    expect(tracks[1].durationIsEstimate, isTrue);
    expect(tracks[1].format, 'mp3');
  });

  group('other files', () {
    test('are ignored, and unreadable audio is reported', () async {
      await put('01.mp3', mp3());
      await put('cover.jpg', [0xFF, 0xD8, 0xFF, 0xE0]);
      await put('notes.txt', utf8.encode('Read by a volunteer.'));
      await put('._01.mp3', List.filled(4096, 0));
      await put('broken.mp3', List.filled(4096, 0));

      final book = await read();
      expect(names(book), ['01.mp3']);
      expect(book.unreadable, ['broken.mp3']);
    });

    test('alone do not make a book', () async {
      await put('cover.jpg', [0xFF, 0xD8, 0xFF, 0xE0]);
      expect(await readFolderBook(folder), isNull);
    });

    test('in subfolders are not read', () async {
      await Directory('${folder.path}/extras').create();
      await File('${folder.path}/extras/bonus.mp3').writeAsBytes(mp3());
      expect(await readFolderBook(folder), isNull);
    });
  });
}
