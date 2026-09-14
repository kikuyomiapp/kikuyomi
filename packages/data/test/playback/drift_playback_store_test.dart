import 'package:drift/drift.dart' hide isNull;
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late KikuyomiDatabase db;
  late FakeClock clock;
  late DriftPlaybackStore store;
  late ({int book, int c1, int c2}) book;

  setUp(() async {
    db = await openSeededDatabase();
    clock = FakeClock(DateTime.utc(2026, 9, 13, 18, 0, 0, 250));
    store = DriftPlaybackStore(db, deviceId: 'this-pc', clock: clock);
    book = await addTwoChapterBook(db);
  });

  tearDown(() => db.close());

  group('progress', () {
    test('is one row per book, replaced by every save', () async {
      await store.saveProgress(
        bookId: book.book,
        position: ChapterPosition(chapterId: book.c1, offsetMs: 10000),
        globalMs: 10000,
      );
      clock.advance(const Duration(seconds: 5));
      await store.saveProgress(
        bookId: book.book,
        position: ChapterPosition(chapterId: book.c2, offsetMs: 5000),
        globalMs: 305000,
      );

      final row = await db.select(db.playbackStates).getSingle();
      expect(row.chapterId, book.c2);
      expect(row.chapterPositionMs, 5000);
      expect(row.globalPositionMs, 305000);
      expect(row.deviceId, 'this-pc');
      expect(row.updatedAt.isAtSameMomentAs(clock.now()), isTrue);
    });

    test("also records the chapter's own last position", () async {
      await store.saveProgress(
        bookId: book.book,
        position: ChapterPosition(chapterId: book.c1, offsetMs: 10000),
        globalMs: 10000,
      );
      final chapter = await (db.select(
        db.chapters,
      )..where((c) => c.id.equals(book.c1))).getSingle();
      expect(chapter.lastPositionMs, 10000);
    });

    test('is exactly what the book resumes from', () async {
      await store.saveProgress(
        bookId: book.book,
        position: ChapterPosition(chapterId: book.c2, offsetMs: 42000),
        globalMs: 342000,
      );
      final stored = await loadStoredPlayback(db, book.book);
      expect(
        stored.resumeFrom,
        ChapterPosition(chapterId: book.c2, offsetMs: 42000),
      );
      expect(stored.lastPlayedAt!.isAtSameMomentAs(clock.now()), isTrue);
    });
  });

  test('a listening session is stored against this device', () async {
    await store.saveSession(
      ListeningSession(
        bookId: book.book,
        chapterId: book.c1,
        startedAt: clock.now(),
        endedAt: clock.now().add(const Duration(minutes: 1)),
        startGlobalMs: 0,
        endGlobalMs: 60000,
        speed: 1.5,
      ),
    );
    final row = await db.select(db.listeningSessions).getSingle();
    expect(row.deviceId, 'this-pc');
    expect(row.chapterId, book.c1);
    expect(row.speed, 1.5);
    expect(row.endGlobalMs, 60000);
  });

  test('speed is remembered on the book', () async {
    await store.saveSpeed(bookId: book.book, speed: 1.75);
    final stored = await loadStoredPlayback(db, book.book);
    expect(stored.speed, 1.75);
  });

  group('a learned duration (§4.5)', () {
    late int bookId;
    late int estimated;
    late int exact;

    Future<MediaFileRow> fileRow(int id) =>
        (db.select(db.mediaFiles)..where((f) => f.id.equals(id))).getSingle();

    Future<BookRow> bookRow() =>
        (db.select(db.books)..where((b) => b.id.equals(bookId))).getSingle();

    setUp(() async {
      // A folder book of two MP3s: the first estimated from its bitrate, the second counted.
      bookId = await addBook(db, key: 'folder');
      estimated = await addFile(
        db,
        bookId,
        'one.mp3',
        durationMs: 300000,
        estimate: true,
      );
      exact = await addFile(db, bookId, 'two.mp3', durationMs: 200000);
      final c1 = await addChapter(db, bookId, 'one', 0);
      final c2 = await addChapter(db, bookId, 'two', 1);
      await addSegment(db, c1, 0, estimated);
      await addSegment(db, c2, 0, exact);
      await (db.update(db.books)..where((b) => b.id.equals(bookId))).write(
        const BooksCompanion(totalDurationMs: Value(500000)),
      );
    });

    test('replaces the estimate and is no longer one', () async {
      await store.saveLearnedDuration(
        bookId: bookId,
        fileId: estimated,
        durationMs: 312000,
      );
      final file = await fileRow(estimated);
      expect(file.durationMs, 312000);
      expect(file.durationIsEstimate, isFalse);
    });

    test("corrects the book's length by the difference", () async {
      await store.saveLearnedDuration(
        bookId: bookId,
        fileId: estimated,
        durationMs: 312000,
      );
      final row = await bookRow();
      expect(row.totalDurationMs, 512000);
      expect(row.updatedAt.isAtSameMomentAs(clock.now()), isTrue);
    });

    test('is what the book plays with next time', () async {
      await store.saveLearnedDuration(
        bookId: bookId,
        fileId: estimated,
        durationMs: 312000,
      );
      final timeline = (await loadStoredPlayback(db, bookId)).timeline;
      expect(timeline.isEstimate, isFalse);
      expect(timeline.totalDurationMs, 512000);
    });

    test('never overwrites a duration that is already exact', () async {
      await store.saveLearnedDuration(
        bookId: bookId,
        fileId: exact,
        durationMs: 205000,
      );
      final file = await fileRow(exact);
      expect(file.durationMs, 200000);
      expect(file.durationIsEstimate, isFalse);
      expect((await bookRow()).totalDurationMs, 500000);
    });

    test("saved twice, corrects the book's length once", () async {
      for (var i = 0; i < 2; i++) {
        await store.saveLearnedDuration(
          bookId: bookId,
          fileId: estimated,
          durationMs: 312000,
        );
      }
      expect((await bookRow()).totalDurationMs, 512000);
    });

    test('leaves a length the user edited as they wrote it', () async {
      await (db.update(db.books)..where((b) => b.id.equals(bookId))).write(
        const BooksCompanion(userOverrides: Value({BookField.totalDurationMs})),
      );
      await store.saveLearnedDuration(
        bookId: bookId,
        fileId: estimated,
        durationMs: 312000,
      );
      expect((await bookRow()).totalDurationMs, 500000);
      expect((await fileRow(estimated)).durationMs, 312000);
    });

    test('ignores a file that belongs to another book', () async {
      await store.saveLearnedDuration(
        bookId: book.book,
        fileId: estimated,
        durationMs: 312000,
      );
      expect((await fileRow(estimated)).durationIsEstimate, isTrue);
    });
  });
}
