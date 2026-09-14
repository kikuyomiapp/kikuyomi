import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/dropped_books.dart';

/// Each item as its kind and name, to compare in one expectation.
List<String> kinds(List<DroppedItem> items) => [
  for (final item in items)
    switch (item) {
      DroppedFile() => 'file ${item.name}',
      DroppedFolder() => 'folder ${item.name}',
      UnsupportedItem() => 'unsupported ${item.name}',
    },
];

/// Each outcome in a few words, to compare in one expectation.
List<String> described(List<DropOutcome> outcomes) => [
  for (final outcome in outcomes)
    switch (outcome) {
      BookAdded(:final title, leftOut: []) => 'added $title',
      BookAdded(:final title, :final leftOut) =>
        'added $title without ${leftOut.join(', ')}',
      BookNotAdded(:final item, :final reason) =>
        'not added ${item.name}: $reason',
      ItemIgnored(:final item) => 'ignored ${item.name}',
    },
];

void main() {
  group('sorting what was dropped', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kikuyomi_dropped_');
    });

    tearDown(() => root.delete(recursive: true));

    String pathOf(String name) => '${root.path}${Platform.pathSeparator}$name';

    /// A file named [name], holding no audio: only names are looked at when sorting.
    String file(String name) =>
        (File(pathOf(name))..writeAsStringSync('Not audio.')).path;

    String folder(String name) => (Directory(pathOf(name))..createSync()).path;

    test(
      'tells audiobook files, folders and anything else apart, in order',
      () async {
        final items = await sortDropped([
          file('One.m4b'),
          folder('Two'),
          file('notes.txt'),
          file('Three.mp3'),
          file('cover.jpg'),
        ]);
        expect(kinds(items), [
          'file One.m4b',
          'folder Two',
          'unsupported notes.txt',
          'file Three.mp3',
          'unsupported cover.jpg',
        ]);
      },
    );

    test('knows every audiobook extension, in any case', () async {
      final items = await sortDropped([
        file('a.MP3'),
        file('b.M4a'),
        file('c.m4B'),
        file('d.mp4'),
      ]);
      expect(kinds(items), [
        'file a.MP3',
        'file b.M4a',
        'file c.m4B',
        'file d.mp4',
      ]);
    });

    test('takes a folder as a folder, whatever its name', () async {
      final items = await sortDropped([
        folder('Looks Like.m4b'),
        folder('Plain'),
      ]);
      expect(kinds(items), ['folder Looks Like.m4b', 'folder Plain']);
    });

    test('sorts a path that is not there by its name', () async {
      final items = await sortDropped([
        pathOf('Gone.m4b'),
        pathOf('Gone.txt'),
        pathOf('Gone'),
      ]);
      expect(kinds(items), [
        'file Gone.m4b',
        'unsupported Gone.txt',
        'unsupported Gone',
      ]);
    });

    test('names an item by the last part of its path', () {
      expect(const DroppedFile(r'C:\Books\One.m4b').name, 'One.m4b');
      expect(const DroppedFolder('/books/Two/').name, 'Two');
    });
  });

  group('adding what was dropped', () {
    test(
      'adds each book once the one before is added, and ignores the rest',
      () async {
        final log = <String>[];
        Future<AddedBook> adding(String kind, String path) async {
          log.add('start $kind $path');
          await Future<void>.delayed(Duration.zero);
          log.add('end $kind $path');
          return (title: 'Book at $path', leftOut: const <String>[]);
        }

        final outcomes = await addDropped(
          const [
            DroppedFolder('/books/One'),
            UnsupportedItem('/books/notes.txt'),
            DroppedFile('/books/Two.m4b'),
          ],
          addFile: (path) => adding('file', path),
          addFolder: (path) => adding('folder', path),
        );
        expect(log, [
          'start folder /books/One',
          'end folder /books/One',
          'start file /books/Two.m4b',
          'end file /books/Two.m4b',
        ]);
        expect(described(outcomes), [
          'added Book at /books/One',
          'ignored notes.txt',
          'added Book at /books/Two.m4b',
        ]);
      },
    );

    test(
      'carries on past books it cannot add, saying why each failed',
      () async {
        final failures = <String, Object>{
          '/books/Not Audio.mp3': const FormatException('not an MP3 file'),
          '/books/Empty': const FormatException('holds no audio'),
          '/books/Gone.m4b': const PathNotFoundException(
            '/books/Gone.m4b',
            OSError(),
          ),
          '/books/Locked.m4b': const PathAccessException(
            '/books/Locked.m4b',
            OSError(),
          ),
          '/books/Damaged.m4a': const FileSystemException('read failed'),
        };
        Future<AddedBook> adding(String path) async {
          if (failures[path] case final failure?) throw failure;
          return (title: 'Walden', leftOut: const ['03.mp3']);
        }

        final outcomes = await addDropped(
          const [
            DroppedFile('/books/Not Audio.mp3'),
            DroppedFolder('/books/Empty'),
            DroppedFile('/books/Gone.m4b'),
            DroppedFile('/books/Locked.m4b'),
            DroppedFile('/books/Damaged.m4a'),
            DroppedFolder('/books/Walden'),
          ],
          addFile: adding,
          addFolder: adding,
        );
        expect(described(outcomes), [
          'not added Not Audio.mp3: it is not audio this app can read',
          'not added Empty: it holds no audio this app can read',
          'not added Gone.m4b: it is no longer there',
          'not added Locked.m4b: this app is not allowed to read it',
          'not added Damaged.m4a: it could not be read',
          'added Walden without 03.mp3',
        ]);
      },
    );
  });

  group('the summary', () {
    BookAdded added(String title, {List<String> leftOut = const []}) =>
        BookAdded(
          DroppedFolder('/books/$title'),
          title: title,
          leftOut: leftOut,
        );

    BookNotAdded notAdded(String name, String reason) =>
        BookNotAdded(DroppedFolder('/books/$name'), reason: reason);

    ItemIgnored ignored(String name) =>
        ItemIgnored(UnsupportedItem('/books/$name'));

    test('names the one book added', () {
      expect(
        summarizeDrop([added('The Time Machine')]),
        'Added The Time Machine',
      );
    });

    test('counts several books added', () {
      expect(summarizeDrop([added('Walden'), added('Emma')]), 'Added 2 books');
    });

    test('says which files were left out of the one book added', () {
      expect(
        summarizeDrop([
          added('Walden', leftOut: ['03.mp3', '07.mp3']),
        ]),
        'Added Walden, leaving out files it could not read: 03.mp3, 07.mp3',
      );
    });

    test('says which files were left out of which book among several', () {
      expect(
        summarizeDrop([
          added('Walden', leftOut: ['03.mp3']),
          added('Emma'),
          added('Middlemarch', leftOut: ['01.mp3', '02.mp3']),
        ]),
        'Added 3 books. '
        'Left out files it could not read from Walden: 03.mp3. '
        'Left out files it could not read from Middlemarch: 01.mp3, 02.mp3',
      );
    });

    test('says what could not be added, and why', () {
      expect(
        summarizeDrop([
          notAdded('Empty', 'it holds no audio this app can read'),
          notAdded('Gone.m4b', 'it is no longer there'),
        ]),
        'Could not add Empty: it holds no audio this app can read. '
        'Could not add Gone.m4b: it is no longer there',
      );
    });

    test('names the one item ignored, and counts several', () {
      expect(
        summarizeDrop([ignored('notes.txt')]),
        'Ignored notes.txt, which is not an audiobook file or folder',
      );
      expect(
        summarizeDrop([ignored('notes.txt'), ignored('cover.jpg')]),
        'Ignored 2 items that are not audiobook files or folders',
      );
    });

    test('tells what became of everything dropped in one message', () {
      expect(
        summarizeDrop([
          ignored('notes.txt'),
          added('Walden'),
          notAdded('Empty', 'it holds no audio this app can read'),
        ]),
        'Added Walden. '
        'Could not add Empty: it holds no audio this app can read. '
        'Ignored notes.txt, which is not an audiobook file or folder',
      );
    });

    test('says what can be added when no files were dropped', () {
      expect(
        summarizeDrop([]),
        'Only audiobook files and folders can be added',
      );
    });
  });
}
