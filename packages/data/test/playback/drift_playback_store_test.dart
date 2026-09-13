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
}
