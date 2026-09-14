import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

// Images for the tests: each format's signature followed by filler, which is all anything here looks
// at. None of them is a picture of anything.
final jpeg = CoverImage(
  mimeType: 'image/jpeg',
  bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(60, 1)]),
);
final png = CoverImage(
  mimeType: 'image/png',
  bytes: Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    ...List.filled(56, 2),
  ]),
);

void main() {
  late KikuyomiDatabase db;
  late FakeClock clock;
  late Directory root;
  late Directory mediaRoot;
  late CoverFiles covers;

  setUp(() async {
    db = KikuyomiDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 9, 14, 21));
    root = await Directory.systemTemp.createTemp('kikuyomi_covers_');
    mediaRoot = await Directory('${root.path}/media').create();
    covers = CoverFiles(Directory('${root.path}/covers'));
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  LocalBookImport m4b({String path = 'Import/A Book.m4b', CoverImage? cover}) =>
      LocalBookImport(
        file: LocalBookFile(path: path, durationMs: 15000, format: 'm4b'),
        title: 'A Book',
        cover: cover,
      );

  LocalFolderImport folder({String key = 'Import/A Book', CoverImage? cover}) =>
      LocalFolderImport(
        key: key,
        title: 'A Book',
        cover: cover,
        tracks: [
          for (final name in ['01.mp3', '02.mp3'])
            LocalTrackImport(
              file: LocalBookFile(path: '$key/$name', durationMs: 60000),
              title: name,
            ),
        ],
      );

  Future<BookRow> row(int bookId) =>
      (db.select(db.books)..where((b) => b.id.equals(bookId))).getSingle();

  Future<void> edit(int bookId, BooksCompanion changes) =>
      (db.update(db.books)..where((b) => b.id.equals(bookId))).write(changes);

  /// The names of the files in the covers folder, temporary ones included.
  List<String> coverFolder() => covers.directory.existsSync()
      ? [
          for (final entity in covers.directory.listSync())
            entity.uri.pathSegments.last,
        ]
      : const [];

  group('adding a book', () {
    test('keeps its picture under its id, and records the name', () async {
      final id = await importLocalBook(
        db,
        m4b(cover: jpeg),
        clock: clock,
        covers: covers,
      );

      final book = await row(id);
      expect(book.coverLocalPath, '$id.jpg');
      expect(book.coverUpdatedAt!.isAtSameMomentAs(clock.now()), isTrue);
      expect(covers.fileOf(book.coverLocalPath)!.readAsBytesSync(), jpeg.bytes);
      expect(coverFolder(), ['$id.jpg']);
    });

    test('in a folder keeps its cover the same way', () async {
      final id = await importLocalFolderBook(
        db,
        folder(cover: png),
        clock: clock,
        covers: covers,
      );

      expect((await row(id)).coverLocalPath, '$id.png');
      expect(coverFolder(), ['$id.png']);
    });

    test(
      'without a picture leaves its cover null, marked as looked for',
      () async {
        final id = await importLocalBook(
          db,
          m4b(),
          clock: clock,
          covers: covers,
        );

        final book = await row(id);
        expect(book.coverLocalPath, isNull);
        expect(book.coverUpdatedAt!.isAtSameMomentAs(clock.now()), isTrue);
        expect(coverFolder(), isEmpty);
        expect(await localBooksAwaitingCover(db), isEmpty);
      },
    );

    test(
      'with a picture of a type the app cannot show records no cover',
      () async {
        final id = await importLocalBook(
          db,
          m4b(
            cover: CoverImage(
              mimeType: 'image/tiff',
              bytes: Uint8List.fromList([0x49, 0x49, 0x2A, 0x00]),
            ),
          ),
          clock: clock,
          covers: covers,
        );

        final book = await row(id);
        expect(book.coverLocalPath, isNull);
        expect(book.coverUpdatedAt, isNotNull);
        expect(coverFolder(), isEmpty);
      },
    );

    test(
      'with no covers folder leaves its cover to be looked for later',
      () async {
        final id = await importLocalBook(db, m4b(cover: jpeg), clock: clock);

        expect((await row(id)).coverUpdatedAt, isNull);
        expect(
          [for (final book in await localBooksAwaitingCover(db)) book.bookId],
          [id],
        );
      },
    );

    test('again does not replace the cover it has', () async {
      final id = await importLocalBook(
        db,
        m4b(cover: jpeg),
        clock: clock,
        covers: covers,
      );
      clock.advance(const Duration(days: 1));
      await importLocalBook(
        db,
        m4b(cover: png),
        clock: clock,
        covers: covers,
      );

      expect((await row(id)).coverLocalPath, '$id.jpg');
      expect(coverFolder(), ['$id.jpg']);
    });

    test(
      'again brings the cover of a book added before covers were kept',
      () async {
        final id = await importLocalBook(db, m4b(), clock: clock);
        await importLocalBook(
          db,
          m4b(cover: jpeg),
          clock: clock,
          covers: covers,
        );
        expect((await row(id)).coverLocalPath, '$id.jpg');
      },
    );

    test('never replaces a cover the user chose', () async {
      final id = await importLocalBook(db, m4b(), clock: clock);
      await edit(
        id,
        const BooksCompanion(userOverrides: Value({BookField.coverUrl})),
      );
      await importLocalBook(
        db,
        m4b(cover: jpeg),
        clock: clock,
        covers: covers,
      );

      final book = await row(id);
      expect(book.coverLocalPath, isNull);
      expect(book.coverUpdatedAt, isNull);
      expect(coverFolder(), isEmpty);
    });

    test('never replaces a cover the book already has', () async {
      final id = await importLocalBook(db, m4b(), clock: clock);
      await edit(id, const BooksCompanion(coverLocalPath: Value('custom.png')));
      await importLocalBook(
        db,
        m4b(cover: jpeg),
        clock: clock,
        covers: covers,
      );

      expect((await row(id)).coverLocalPath, 'custom.png');
      expect(coverFolder(), isEmpty);
    });

    test('still succeeds when its cover cannot be written', () async {
      // A file where the covers folder should be, so the folder cannot be made.
      final blocked = File('${root.path}/blocked')..writeAsBytesSync([0]);
      final id = await importLocalBook(
        db,
        m4b(cover: jpeg),
        clock: clock,
        covers: CoverFiles(Directory(blocked.path)),
      );

      final book = await row(id);
      expect(book.inLibrary, isTrue);
      expect(book.coverUpdatedAt, isNull);
    });
  });

  group('looking for covers later', () {
    /// Where the reader was asked to look, one entry per book read.
    late List<(String, String?)> reads;

    setUp(() => reads = []);

    /// A reader that finds [cover] in every book.
    LocalCoverReader finding(CoverImage? cover) => (audio, folder) async {
      reads.add((audio.path, folder?.path));
      return cover;
    };

    Future<void> lookForCovers(LocalCoverReader read) async {
      for (final book in await localBooksAwaitingCover(db)) {
        await lookForLocalCover(
          db,
          book,
          mediaRoot: mediaRoot,
          read: read,
          covers: covers,
          clock: clock,
        );
      }
    }

    /// Creates a file at [path], relative to the media root.
    void put(String path) => File('${mediaRoot.path}/$path')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);

    test(
      'finds the books in the library whose cover was never looked for',
      () async {
        final single = await importLocalBook(db, m4b(), clock: clock);
        final inFolder = await importLocalFolderBook(
          db,
          folder(),
          clock: clock,
        );
        final absolute = '${mediaRoot.path}/Elsewhere.m4b';
        final elsewhere = await importLocalBook(
          db,
          m4b(path: absolute),
          clock: clock,
        );
        final removed = await importLocalBook(
          db,
          m4b(path: 'Import/Removed.m4b'),
          clock: clock,
        );
        await removeBookFromLibrary(db, removed, clock: clock);
        await importLocalBook(
          db,
          m4b(path: 'Import/Done.m4b'),
          clock: clock,
          covers: covers,
        );

        expect(
          [
            for (final book in await localBooksAwaitingCover(db))
              (book.bookId, book.audioPath, book.folderPath),
          ],
          [
            (elsewhere, absolute, null),
            (inFolder, 'Import/A Book/01.mp3', 'Import/A Book'),
            (single, 'Import/A Book.m4b', null),
          ],
        );
      },
    );

    test("stores the cover found in a book's file", () async {
      put('Import/A Book.m4b');
      final id = await importLocalBook(db, m4b(), clock: clock);

      await lookForCovers(finding(jpeg));

      expect(reads, [('${mediaRoot.path}/Import/A Book.m4b', null)]);
      final book = await row(id);
      expect(book.coverLocalPath, '$id.jpg');
      expect(book.coverUpdatedAt!.isAtSameMomentAs(clock.now()), isTrue);
      expect(covers.fileOf(book.coverLocalPath)!.readAsBytesSync(), jpeg.bytes);
    });

    test(
      'reads a book in a folder from its first file and the folder',
      () async {
        put('Import/A Book/01.mp3');
        put('Import/A Book/02.mp3');
        final id = await importLocalFolderBook(db, folder(), clock: clock);

        await lookForCovers(finding(png));

        expect(reads, [
          (
            '${mediaRoot.path}/Import/A Book/01.mp3',
            '${mediaRoot.path}/Import/A Book',
          ),
        ]);
        expect((await row(id)).coverLocalPath, '$id.png');
      },
    );

    test('marks a book with no cover, and does not read it again', () async {
      put('Import/A Book.m4b');
      final id = await importLocalBook(db, m4b(), clock: clock);

      await lookForCovers(finding(null));
      await lookForCovers(finding(null));

      expect(reads, hasLength(1));
      final book = await row(id);
      expect(book.coverLocalPath, isNull);
      expect(book.coverUpdatedAt, isNotNull);
    });

    test(
      'skips a book whose file is missing, to look again another time',
      () async {
        final id = await importLocalBook(db, m4b(), clock: clock);

        await lookForCovers(finding(jpeg));

        expect(reads, isEmpty);
        expect((await row(id)).coverUpdatedAt, isNull);
        expect(await localBooksAwaitingCover(db), hasLength(1));
      },
    );

    test('skips a book whose file cannot be read', () async {
      put('Import/A Book.m4b');
      final id = await importLocalBook(db, m4b(), clock: clock);

      await lookForCovers(
        (audio, folder) async =>
            throw FileSystemException('Cannot open', audio.path),
      );

      expect((await row(id)).coverUpdatedAt, isNull);
    });

    test(
      'leaves alone a book whose cover was kept since it was listed',
      () async {
        put('Import/A Book.m4b');
        final id = await importLocalBook(db, m4b(), clock: clock);
        final awaiting = await localBooksAwaitingCover(db);
        await importLocalBook(
          db,
          m4b(cover: jpeg),
          clock: clock,
          covers: covers,
        );

        await lookForLocalCover(
          db,
          awaiting.single,
          mediaRoot: mediaRoot,
          read: finding(png),
          covers: covers,
          clock: clock,
        );

        expect((await row(id)).coverLocalPath, '$id.jpg');
      },
    );
  });
}
