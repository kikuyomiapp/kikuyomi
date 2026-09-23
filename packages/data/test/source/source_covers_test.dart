import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart' as api;
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

const sourceId = 0x4c4942;

api.BookDetails book({
  String key = '9638',
  String? coverUrl = 'https://archive.org/services/img/yellowstone',
}) => api.BookDetails(
  key: key,
  title: 'Yellowstone National Park',
  authors: const ['Various'],
  coverUrl: coverUrl == null ? null : Uri.parse(coverUrl),
  totalDurationMs: 60000,
);

final chapters = [
  const api.ChapterInfo(key: 's1', title: 'Hayden', durationMs: 60000),
];

/// A one-pixel image, standing in for whatever the source serves.
final anImage = CoverImage(
  mimeType: 'image/jpeg',
  bytes: Uint8List.fromList(const [0xff, 0xd8, 0xff, 0xd9]),
);

void main() {
  late KikuyomiDatabase db;
  late FakeClock clock;
  late Directory folder;
  late CoverFiles covers;

  setUp(() async {
    db = KikuyomiDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 9, 23, 12));
    folder = Directory.systemTemp.createTempSync('kikuyomi-covers');
    covers = CoverFiles(folder);
    await registerSource(
      db,
      id: sourceId,
      key: 'librivox',
      name: 'LibriVox',
      lang: 'multi',
      extensionId: 'org.kikuyomi.librivox',
    );
  });

  tearDown(() async {
    await db.close();
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  Future<int> add({api.BookDetails? details, bool toLibrary = true}) async {
    final saved = await saveSourceBook(
      db,
      sourceId: sourceId,
      details: details ?? book(),
      chapters: chapters,
      clock: clock,
      addToLibrary: toLibrary,
    );
    return saved.bookId;
  }

  test('a book just added is waiting for the cover its source named', () async {
    final bookId = await add();

    final waiting = await booksAwaitingSourceCover(db);

    expect(waiting.single.bookId, bookId);
    expect(waiting.single.sourceId, sourceId);
    expect(
      waiting.single.coverUrl,
      Uri.parse('https://archive.org/services/img/yellowstone'),
    );
  });

  test('the image fetched for it lands in the covers folder', () async {
    final bookId = await add();
    final waiting = (await booksAwaitingSourceCover(db)).single;

    await keepBookCover(
      db,
      waiting.bookId,
      anImage,
      covers: covers,
      clock: clock,
    );

    final row = await (db.select(
      db.books,
    )..where((b) => b.id.equals(bookId))).getSingle();
    expect(row.coverLocalPath, '$bookId.jpg');
    expect(row.coverUpdatedAt, clock.now());
    expect(covers.fileOf(row.coverLocalPath)!.existsSync(), isTrue);
    // And the book's details screen names it, which is how it is shown.
    expect(
      (await watchBookOverview(db, bookId).first)!.coverFileName,
      '$bookId.jpg',
    );
  });

  test('a book whose cover has been kept is not asked for again', () async {
    await add();
    final waiting = (await booksAwaitingSourceCover(db)).single;
    await keepBookCover(
      db,
      waiting.bookId,
      anImage,
      covers: covers,
      clock: clock,
    );

    expect(await booksAwaitingSourceCover(db), isEmpty);
  });

  test(
    'a cover that turns out not to be there is not looked for again',
    () async {
      // Recording that there is none is what stops a book being fetched at every start.
      await add();
      final waiting = (await booksAwaitingSourceCover(db)).single;

      await keepBookCover(
        db,
        waiting.bookId,
        null,
        covers: covers,
        clock: clock,
      );

      expect(await booksAwaitingSourceCover(db), isEmpty);
    },
  );

  test('a book with no cover URL is never waiting for one', () async {
    await add(details: book(coverUrl: null));

    expect(await booksAwaitingSourceCover(db), isEmpty);
  });

  test('a book only browsed, not added, is left alone', () async {
    await add(toLibrary: false);

    expect(await booksAwaitingSourceCover(db), isEmpty);
  });

  test('local books are left to their own search', () async {
    await importLocalBook(
      db,
      LocalBookImport(
        file: const LocalBookFile(path: '/books/a.m4b', durationMs: 1000),
        title: 'A Local Book',
      ),
      clock: clock,
    );

    expect(await booksAwaitingSourceCover(db), isEmpty);
  });

  test('a cover the listener chose survives a refresh (§4.4)', () async {
    final bookId = await add();
    await (db.update(db.books)..where((b) => b.id.equals(bookId))).write(
      BooksCompanion(userOverrides: Value({BookField.coverUrl})),
    );

    await add(
      details: book(
        coverUrl: 'https://archive.org/services/img/something-else',
      ),
    );

    expect(await booksAwaitingSourceCover(db), isEmpty);
    final row = await (db.select(
      db.books,
    )..where((b) => b.id.equals(bookId))).getSingle();
    expect(row.coverUrl, 'https://archive.org/services/img/yellowstone');
  });

  test('a cover URL that changed is fetched again', () async {
    final bookId = await add();
    final waiting = (await booksAwaitingSourceCover(db)).single;
    await keepBookCover(
      db,
      waiting.bookId,
      anImage,
      covers: covers,
      clock: clock,
    );

    await add(
      details: book(coverUrl: 'https://archive.org/services/img/other'),
    );

    final again = await booksAwaitingSourceCover(db);
    expect(again.single.bookId, bookId);
    expect(
      again.single.coverUrl,
      Uri.parse('https://archive.org/services/img/other'),
    );
  });
}
