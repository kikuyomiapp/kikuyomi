import 'package:drift/drift.dart' hide isNull;
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late KikuyomiDatabase db;

  setUp(() async => db = await openSeededDatabase());
  tearDown(() => db.close());

  Future<void> saveState(int bookId, int chapterId, int offsetMs) async {
    await db
        .into(db.playbackStates)
        .insert(
          PlaybackStatesCompanion(
            bookId: Value(bookId),
            chapterId: Value(chapterId),
            chapterPositionMs: Value(offsetMs),
            globalPositionMs: Value(offsetMs),
            updatedAt: Value(seedTime),
            deviceId: const Value('test-device'),
          ),
        );
  }

  group('the Timeline', () {
    test('is built from the stored layout', () async {
      final b = await addTwoChapterBook(db);
      final stored = await loadStoredPlayback(db, b.book);

      expect(stored.timeline.chapterIds, [b.c1, b.c2]);
      expect(stored.timeline.totalDurationMs, 600000);
      expect(stored.timeline.queue, hasLength(2));
      expect(stored.speed, 1.25);
      expect(stored.resumeFrom, isNull);
      expect(stored.lastPlayedAt, isNull);
    });

    test('orders chapters by source index, not insertion order', () async {
      final book = await addBook(db);
      final file = await addFile(db, book, 'book.m4b', durationMs: 600000);
      final second = await addChapter(db, book, 'second', 1);
      final first = await addChapter(db, book, 'first', 0);
      await addSegment(db, second, 0, file, startMs: 200000);
      await addSegment(db, first, 0, file, endMs: 200000);

      final stored = await loadStoredPlayback(db, book);
      expect(stored.timeline.chapterIds, [first, second]);
    });

    test('lets a segment with no end run to the end of its file', () async {
      final book = await addBook(db);
      final file = await addFile(db, book, 'book.m4b', durationMs: 600000);
      final c1 = await addChapter(db, book, 'one', 0);
      final c2 = await addChapter(db, book, 'two', 1);
      await addSegment(db, c1, 0, file, endMs: 200000);
      await addSegment(db, c2, 0, file, startMs: 200000);

      final timeline = (await loadStoredPlayback(db, book)).timeline;
      expect(timeline.chapterDurationMs(c2), 400000);
      expect(timeline.queue, hasLength(1));
    });

    test('leaves out chapters removed from the source', () async {
      final b = await addTwoChapterBook(db);
      final file = await addFile(db, b.book, 'extra.mp3', durationMs: 1000);
      final gone = await addChapter(db, b.book, 'gone', 2, removed: true);
      await addSegment(db, gone, 0, file);

      final stored = await loadStoredPlayback(db, b.book);
      expect(stored.timeline.chapterIds, [b.c1, b.c2]);
    });

    test('carries embedded markers into navigation', () async {
      final book = await addBook(db);
      final file = await addFile(
        db,
        book,
        'book.m4b',
        durationMs: 600000,
        markers: const [
          TimelineMarker(title: 'Opening', startMs: 0),
          TimelineMarker(title: 'Middle', startMs: 300000),
        ],
      );
      final chapter = await addChapter(db, book, 'whole', 0);
      await addSegment(db, chapter, 0, file);

      final navigation = (await loadStoredPlayback(
        db,
        book,
      )).timeline.navigation;
      expect(
        [for (final entry in navigation.whereType<MarkerEntry>()) entry.title],
        ['Opening', 'Middle'],
      );
    });

    test('knows which durations are still estimates', () async {
      final book = await addBook(db);
      final file = await addFile(
        db,
        book,
        'part1.mp3',
        durationMs: 300000,
        estimate: true,
      );
      final chapter = await addChapter(db, book, 'one', 0);
      await addSegment(db, chapter, 0, file);

      expect((await loadStoredPlayback(db, book)).timeline.isEstimate, isTrue);
    });
  });

  group('unplayable books', () {
    test('a file with no known duration', () async {
      final book = await addBook(db);
      final file = await addFile(db, book, 'unprobed.mp3');
      final chapter = await addChapter(db, book, 'one', 0);
      await addSegment(db, chapter, 0, file);

      expect(
        loadStoredPlayback(db, book),
        throwsA(isA<UnplayableBookException>()),
      );
    });

    test('no chapter with a known layout', () async {
      final book = await addBook(db);
      await addChapter(db, book, 'one', 0);
      expect(
        loadStoredPlayback(db, book),
        throwsA(isA<UnplayableBookException>()),
      );
    });

    test('a book that does not exist', () async {
      expect(loadStoredPlayback(db, 999), throwsArgumentError);
    });
  });

  group('resuming', () {
    test('picks up the saved position', () async {
      final b = await addTwoChapterBook(db);
      await saveState(b.book, b.c2, 42000);

      final stored = await loadStoredPlayback(db, b.book);
      expect(
        stored.resumeFrom,
        ChapterPosition(chapterId: b.c2, offsetMs: 42000),
      );
      expect(stored.lastPlayedAt!.isAtSameMomentAs(seedTime), isTrue);
    });

    test(
      'moves on to the next chapter when the saved one was removed',
      () async {
        final b = await addTwoChapterBook(db);
        final file = await addFile(db, b.book, 'part3.mp3', durationMs: 1000);
        final c3 = await addChapter(db, b.book, 'three', 2);
        await addSegment(db, c3, 0, file);
        await saveState(b.book, b.c2, 42000);
        await markRemoved(db, b.c2);

        final stored = await loadStoredPlayback(db, b.book);
        expect(stored.resumeFrom, ChapterPosition(chapterId: c3, offsetMs: 0));
      },
    );

    test('gives up the position only when nothing follows', () async {
      final b = await addTwoChapterBook(db);
      await saveState(b.book, b.c2, 42000);
      await markRemoved(db, b.c2);

      expect((await loadStoredPlayback(db, b.book)).resumeFrom, isNull);
    });
  });

  group('a finished book (§4.5)', () {
    Future<void> setListened(int chapterId) async {
      await (db.update(db.chapters)..where((c) => c.id.equals(chapterId)))
          .write(const ChaptersCompanion(isListened: Value(true)));
    }

    test('is one whose last chapter is recorded as listened', () async {
      final b = await addTwoChapterBook(db);
      expect((await loadStoredPlayback(db, b.book)).finished, isFalse);
      await setListened(b.c1);
      expect((await loadStoredPlayback(db, b.book)).finished, isFalse);
      await setListened(b.c2);
      expect((await loadStoredPlayback(db, b.book)).finished, isTrue);
    });

    test('is judged by the last chapter the player plays', () async {
      final b = await addTwoChapterBook(db);
      await setListened(b.c1);
      await markRemoved(db, b.c2);
      expect((await loadStoredPlayback(db, b.book)).finished, isTrue);
    });
  });
}
