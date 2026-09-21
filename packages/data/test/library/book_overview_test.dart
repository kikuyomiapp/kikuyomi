import 'package:drift/drift.dart' hide isNull;
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late KikuyomiDatabase db;
  late FakeClock clock;

  setUp(() {
    db = openDatabase();
    clock = FakeClock(start);
  });

  tearDown(() => db.close());

  Future<BookOverview> overview(int bookId) async =>
      (await watchBookOverview(db, bookId).first)!;

  Future<List<bool>> listened(int bookId) async => [
    for (final chapter in (await overview(bookId)).chapters) chapter.listened,
  ];

  test('is null for a book that does not exist', () async {
    expect(await watchBookOverview(db, 999).first, isNull);
  });

  test("names the book's cover, once it has one", () async {
    final id = await addFolderBook(db, clock);
    expect((await overview(id)).coverFileName, isNull);

    await (db.update(db.books)..where((b) => b.id.equals(id))).write(
      BooksCompanion(coverLocalPath: Value('$id.jpg')),
    );
    expect((await overview(id)).coverFileName, '$id.jpg');
  });

  test("has the book's title, its credits in order and its length", () async {
    final id = await addFolderBook(
      db,
      clock,
      narrators: const ['A Narrator', 'Second Narrator'],
    );

    final book = await overview(id);
    expect(book.bookId, id);
    expect(book.title, 'A Book');
    expect(book.authors, ['An Author', 'Second Author']);
    expect(book.narrators, ['A Narrator', 'Second Narrator']);
    expect(book.totalDurationMs, 2100000);
    expect(book.inLibrary, isTrue);
    expect(book.progress, isNull);
    expect(book.markers, isEmpty);
  });

  test('lists the chapters in source order with their durations', () async {
    final id = await addFolderBook(db, clock);

    final chapters = (await overview(id)).chapters;
    expect([for (final c in chapters) c.chapterId], await chapterIdsOf(db, id));
    expect([for (final c in chapters) c.title], ['Opening', 'Middle', 'End']);
    expect([for (final c in chapters) c.durationMs], [600000, 1200000, 300000]);
    expect([for (final c in chapters) c.listened], [false, false, false]);
    expect([for (final c in chapters) c.current], [false, false, false]);
  });

  test('leaves out chapters the source no longer reports', () async {
    final id = await addFolderBook(db, clock);
    final chapters = await chapterIdsOf(db, id);
    await (db.update(db.chapters)..where((c) => c.id.equals(chapters[1])))
        .write(const ChaptersCompanion(removedFromSource: Value(true)));

    expect(
      [for (final c in (await overview(id)).chapters) c.title],
      ['Opening', 'End'],
    );
  });

  test('takes durations from the files, as the player does', () async {
    final id = await addFolderBook(db, clock);
    // Probing found the second file ten seconds longer than first thought.
    await (db.update(db.mediaFiles)
          ..where((f) => f.fileKey.equals('C:/Books/A Book/2.mp3')))
        .write(const MediaFilesCompanion(durationMs: Value(1210000)));

    expect(
      [for (final c in (await overview(id)).chapters) c.durationMs],
      [600000, 1210000, 300000],
    );
  });

  test('still describes a book that cannot be played yet', () async {
    final id = await addFolderBook(db, clock);
    await listen(db, clock, id, 2, 300000);
    await (db.update(db.mediaFiles)..where((f) => f.bookId.equals(id))).write(
      const MediaFilesCompanion(durationMs: Value(null)),
    );

    final book = await overview(id);
    expect(
      [for (final c in book.chapters) c.durationMs],
      [600000, 1200000, 300000],
    );
    expect(
      book.finished,
      isTrue,
      reason: 'it was recorded finished, and is read, not worked out',
    );
  });

  group('listened chapters', () {
    test(
      'reach their duration less the larger of 30 seconds or 3 percent',
      () async {
        final id = await addFolderBook(db, clock);
        // Opening lasts 10 minutes, so 30 seconds is the larger: listened from 9:30.
        await listen(db, clock, id, 0, 570000);
        // Middle lasts 20 minutes, so 3 percent is the larger: listened from 19:24.
        await listen(db, clock, id, 1, 1163999);
        expect(await listened(id), [true, false, false]);

        await listen(db, clock, id, 1, 1164000);
        expect(await listened(id), [true, true, false]);
      },
    );

    test('keep their own positions as the listener moves on', () async {
      final id = await addFolderBook(db, clock);
      await listen(db, clock, id, 0, 300000);
      await listen(db, clock, id, 2, 10000);

      final chapters = (await overview(id)).chapters;
      expect([for (final c in chapters) c.listened], [false, false, false]);
      expect([for (final c in chapters) c.current], [false, false, true]);
    });

    test('do not include a short chapter not yet reached', () async {
      final id = await addFolderBook(
        db,
        clock,
        parts: const [('One', 20000), ('Two', 20000), ('Three', 20000)],
      );
      expect(await listened(id), [false, false, false]);

      // At 30 seconds or less the threshold is zero, so being in the chapter is enough.
      await listen(db, clock, id, 1, 0);
      expect(await listened(id), [false, true, false]);
    });

    test(
      'include a chapter marked listened, wherever the listener is',
      () async {
        final id = await addFolderBook(db, clock);
        final chapters = await chapterIdsOf(db, id);
        await (db.update(db.chapters)..where((c) => c.id.equals(chapters[2])))
            .write(const ChaptersCompanion(isListened: Value(true)));

        expect(await listened(id), [false, false, true]);
      },
    );

    test(
      'read as not listened once marked so, wherever the listener is',
      () async {
        final id = await addFolderBook(db, clock);
        final chapters = await chapterIdsOf(db, id);
        await listen(db, clock, id, 0, 600000);
        await listen(db, clock, id, 1, 1200000);
        await mark(db, clock, id, [chapters[0], chapters[1]], listened: false);

        final book = await overview(id);
        expect(
          [for (final c in book.chapters) c.listened],
          [false, false, false],
        );
        expect(book.progress!.chapterPositionMs, 1200000);
      },
    );
  });

  test('has every marker listened once the single file is', () async {
    final id = await addM4b(db, clock);
    // An hour less 3 percent is 58:12.
    await listen(db, clock, id, 0, 3492000);

    final book = await overview(id);
    expect(book.finished, isTrue);
    expect([for (final m in book.markers) m.listened], [true, true, true]);
    expect([for (final m in book.markers) m.current], [false, false, true]);
  });

  test("presents a single file's embedded markers as its chapters", () async {
    final id = await addM4b(db, clock);
    await listen(db, clock, id, 0, 1500000);

    final book = await overview(id);
    expect(book.chapters, hasLength(1));
    expect(
      [for (final m in book.markers) m.title],
      ['Chapter One', 'Chapter Two', 'Chapter Three'],
    );
    expect(
      [for (final m in book.markers) (m.startMs, m.endMs)],
      [(0, 1200000), (1200000, 2400000), (2400000, 3600000)],
    );
    // A marker has no listened state of its own: the file's one chapter is not listened yet.
    expect([for (final m in book.markers) m.listened], [false, false, false]);
    expect([for (final m in book.markers) m.current], [false, true, false]);
  });

  test('has no marker listened before a single file is started', () async {
    final id = await addM4b(db, clock);
    final markers = (await overview(id)).markers;
    expect([for (final m in markers) m.listened], [false, false, false]);
    expect([for (final m in markers) m.current], [false, false, false]);
  });

  group('progress', () {
    test('is where the listener last was', () async {
      final id = await addFolderBook(db, clock);
      await listen(db, clock, id, 1, 60000);

      final progress = (await overview(id)).progress!;
      expect(progress.chapterId, (await chapterIdsOf(db, id))[1]);
      expect(progress.chapterPositionMs, 60000);
      expect(progress.globalPositionMs, 660000);
      expect(progress.lastPlayedAt.isAtSameMomentAs(start), isTrue);
      expect((await overview(id)).finished, isFalse);
    });

    test('says when the book is finished', () async {
      final id = await addFolderBook(db, clock);
      await listen(db, clock, id, 2, 300000);
      expect((await overview(id)).finished, isTrue);
    });
  });

  test('updates by itself when progress is saved', () async {
    final id = await addFolderBook(db, clock);
    final shown = expectLater(
      watchBookOverview(
        db,
        id,
      ).map((book) => book?.progress?.chapterPositionMs),
      emitsThrough(60000),
    );
    await listen(db, clock, id, 1, 60000);
    await shown;
  });
}
