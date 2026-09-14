import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
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

  Future<List<BookmarkOverview>> bookmarksOf(int bookId) =>
      watchBookmarks(db, bookId).first;

  /// Bookmarks [offsetMs] into the chapter at [chapterIndex] in source order, removed chapters
  /// included, then moves the clock on a minute so that the next bookmark is made later.
  Future<int> mark(
    int bookId,
    int chapterIndex,
    int offsetMs, {
    String? title,
    String? note,
  }) async {
    final chapters = await chapterIdsOf(db, bookId);
    final id = await addBookmark(
      db,
      bookId: bookId,
      position: ChapterPosition(
        chapterId: chapters[chapterIndex],
        offsetMs: offsetMs,
      ),
      clock: clock,
      title: title,
      note: note,
    );
    clock.advance(const Duration(minutes: 1));
    return id;
  }

  /// The watched bookmarks of [bookId], one list at a time, cancelled when the test ends.
  StreamIterator<List<BookmarkOverview>> watch(int bookId) {
    final shown = StreamIterator(watchBookmarks(db, bookId));
    addTearDown(shown.cancel);
    return shown;
  }

  Future<List<BookmarkOverview>> next(
    StreamIterator<List<BookmarkOverview>> shown,
  ) async {
    expect(await shown.moveNext(), isTrue);
    return shown.current;
  }

  Future<void> markRemoved(int chapterId) async {
    await (db.update(db.chapters)..where((c) => c.id.equals(chapterId))).write(
      const ChaptersCompanion(removedFromSource: Value(true)),
    );
  }

  test('are none for a book with none, or for no book at all', () async {
    final id = await addFolderBook(db, clock);
    expect(await bookmarksOf(id), isEmpty);
    expect(await bookmarksOf(999), isEmpty);
  });

  group('added', () {
    test(
      'keep their chapter, offset, name, note and when they were made',
      () async {
        final id = await addFolderBook(db, clock);
        final chapters = await chapterIdsOf(db, id);
        final bookmark = await mark(
          id,
          1,
          60000,
          title: 'The twist',
          note: 'Listen again',
        );

        final shown = (await bookmarksOf(id)).single;
        expect(shown.bookmarkId, bookmark);
        expect(shown.bookId, id);
        expect(shown.chapterId, chapters[1]);
        expect(shown.chapterPositionMs, 60000);
        expect(shown.title, 'The twist');
        expect(shown.note, 'Listen again');
        expect(shown.createdAt.isAtSameMomentAs(start), isTrue);
        expect(shown.chapterTitle, 'Middle');
        expect(shown.globalPositionMs, 660000);
        expect(shown.removedFromSource, isFalse);
      },
    );

    test('store a name or note trimmed, and a blank one as none', () async {
      final id = await addFolderBook(db, clock);
      await mark(id, 0, 0, title: '  Named  ', note: ' \n ');
      await mark(id, 0, 1000);

      final shown = await bookmarksOf(id);
      expect(
        [for (final b in shown) (b.title, b.note)],
        [('Named', null), (null, null)],
      );
    });

    test('are refused outside the chapters of their book', () async {
      final id = await addFolderBook(db, clock);
      final other = await addM4b(db, clock);
      final otherChapter = (await chapterIdsOf(db, other)).single;
      final chapter = (await chapterIdsOf(db, id)).first;

      await expectLater(
        addBookmark(
          db,
          bookId: id,
          position: ChapterPosition(chapterId: otherChapter, offsetMs: 0),
          clock: clock,
        ),
        throwsArgumentError,
      );
      await expectLater(
        addBookmark(
          db,
          bookId: id,
          position: ChapterPosition(chapterId: chapter, offsetMs: -1),
          clock: clock,
        ),
        throwsArgumentError,
      );
      expect(await bookmarksOf(id), isEmpty);
    });
  });

  test('are renamed and noted afresh, and cleared with a blank', () async {
    final id = await addFolderBook(db, clock);
    final bookmark = await mark(id, 0, 0, title: 'Before', note: 'Old note');

    await renameBookmark(db, bookmark, ' After ');
    await setBookmarkNote(db, bookmark, 'New note');
    expect(
      [for (final b in await bookmarksOf(id)) (b.title, b.note)],
      [('After', 'New note')],
    );

    await renameBookmark(db, bookmark, '   ');
    await setBookmarkNote(db, bookmark, null);
    expect(
      [for (final b in await bookmarksOf(id)) (b.title, b.note)],
      [(null, null)],
    );
  });

  group('deleted', () {
    test('leave the others', () async {
      final id = await addFolderBook(db, clock);
      final first = await mark(id, 0, 0);
      final second = await mark(id, 2, 0);

      await deleteBookmark(db, first);
      expect([for (final b in await bookmarksOf(id)) b.bookmarkId], [second]);
    });

    test('come back as they were, in their place, when restored', () async {
      final id = await addFolderBook(db, clock);
      await mark(id, 0, 0);
      final middle = await mark(id, 1, 5000, title: 'Named', note: 'Noted');
      await mark(id, 2, 0);
      final before = await bookmarksOf(id);
      final deleted = before[1];
      expect(deleted.bookmarkId, middle);

      await deleteBookmark(db, middle);
      expect(await bookmarksOf(id), hasLength(2));

      await restoreBookmark(db, deleted);
      final after = await bookmarksOf(id);
      expect(
        [for (final b in after) b.bookmarkId],
        [for (final b in before) b.bookmarkId],
      );
      final restored = after[1];
      expect(restored.chapterId, deleted.chapterId);
      expect(restored.chapterPositionMs, 5000);
      expect((restored.title, restored.note), ('Named', 'Noted'));
      expect(restored.createdAt.isAtSameMomentAs(deleted.createdAt), isTrue);
    });

    test('are restored only once', () async {
      final id = await addFolderBook(db, clock);
      await mark(id, 0, 0);
      final bookmark = (await bookmarksOf(id)).single;

      await deleteBookmark(db, bookmark.bookmarkId);
      await restoreBookmark(db, bookmark);
      await restoreBookmark(db, bookmark);
      expect(await bookmarksOf(id), hasLength(1));
    });
  });

  test('are in playing order, then in the order they were made', () async {
    final id = await addFolderBook(db, clock);
    final inEnd = await mark(id, 2, 10000);
    final laterInOpening = await mark(id, 0, 500000);
    final inMiddle = await mark(id, 1, 0);
    final earlierInOpening = await mark(id, 0, 1000);
    final alsoInMiddle = await mark(id, 1, 0);

    final shown = await bookmarksOf(id);
    expect(
      [for (final b in shown) b.bookmarkId],
      [earlierInOpening, laterInOpening, inMiddle, alsoInMiddle, inEnd],
    );
    expect(
      [for (final b in shown) b.globalPositionMs],
      [1000, 500000, 600000, 600000, 1810000],
    );
  });

  test('name the chapter they are in, even at its very end', () async {
    final id = await addFolderBook(db, clock);
    // The very end of Opening, which in global time is also where Middle starts.
    await mark(id, 0, 600000);

    final shown = (await bookmarksOf(id)).single;
    expect(shown.chapterTitle, 'Opening');
    expect(shown.globalPositionMs, 600000);
  });

  test("take their names from a single file's embedded markers", () async {
    final id = await addM4b(db, clock);
    await mark(id, 0, 1500000);
    await mark(id, 0, 0);

    final shown = await bookmarksOf(id);
    expect(
      [for (final b in shown) b.chapterTitle],
      ['Chapter One', 'Chapter Two'],
    );
    expect([for (final b in shown) b.globalPositionMs], [0, 1500000]);
    // Anchored to the one chapter spanning the file, not to a marker.
    expect(
      {for (final b in shown) b.chapterId},
      {(await chapterIdsOf(db, id)).single},
    );
  });

  test('move with a duration refined as the book plays', () async {
    final id = await addFolderBook(db, clock);
    final inOpening = await mark(id, 0, 1000);
    final inMiddle = await mark(id, 1, 60000);
    // The first file's length turns out to have been estimated ten seconds short.
    const firstFile = 'C:/Books/A Book/1.mp3';
    await (db.update(db.mediaFiles)..where((f) => f.fileKey.equals(firstFile)))
        .write(const MediaFilesCompanion(durationIsEstimate: Value(true)));
    final file = await (db.select(
      db.mediaFiles,
    )..where((f) => f.fileKey.equals(firstFile))).getSingle();

    final shown = watch(id);
    expect(
      [for (final b in await next(shown)) b.globalPositionMs],
      [1000, 660000],
    );

    await DriftPlaybackStore(
      db,
      deviceId: 'test-device',
      clock: clock,
    ).saveLearnedDuration(bookId: id, fileId: file.id, durationMs: 610000);
    expect(
      [
        for (final b in await next(shown))
          (b.bookmarkId, b.chapterPositionMs, b.globalPositionMs),
      ],
      [(inOpening, 1000, 1000), (inMiddle, 60000, 670000)],
    );
  });

  group('in a chapter the source no longer reports', () {
    test('stay in their place, marked, with nowhere to go to', () async {
      final id = await addFolderBook(db, clock);
      final chapters = await chapterIdsOf(db, id);
      await mark(id, 0, 1000);
      await mark(id, 1, 60000, title: 'Kept');
      await mark(id, 2, 1000);
      await markRemoved(chapters[1]);

      final shown = await bookmarksOf(id);
      expect(
        [for (final b in shown) b.chapterTitle],
        ['Opening', 'Middle', 'End'],
      );
      expect(
        [for (final b in shown) b.removedFromSource],
        [false, true, false],
      );
      // The player's book no longer has Middle, so End follows straight on from Opening.
      expect([for (final b in shown) b.globalPositionMs], [1000, null, 601000]);
      expect(shown[1].title, 'Kept');
      expect(shown[1].chapterPositionMs, 60000);
    });

    test('can still be renamed, noted and deleted', () async {
      final id = await addFolderBook(db, clock);
      final bookmark = await mark(id, 1, 60000);
      await markRemoved((await chapterIdsOf(db, id))[1]);

      await renameBookmark(db, bookmark, 'Named');
      await setBookmarkNote(db, bookmark, 'Noted');
      final shown = (await bookmarksOf(id)).single;
      expect((shown.title, shown.note), ('Named', 'Noted'));

      await deleteBookmark(db, bookmark);
      expect(await bookmarksOf(id), isEmpty);
    });
  });

  test('in a chapter with no layout have nowhere to go to', () async {
    final id = await addFolderBook(db, clock);
    final chapters = await chapterIdsOf(db, id);
    await mark(id, 1, 60000);
    await mark(id, 2, 1000);
    await (db.delete(
      db.chapterSegments,
    )..where((s) => s.chapterId.equals(chapters[1]))).go();

    final shown = await bookmarksOf(id);
    expect([for (final b in shown) b.globalPositionMs], [null, 601000]);
    expect([for (final b in shown) b.removedFromSource], [false, false]);
    expect(shown.first.chapterTitle, 'Middle');
  });

  test('of a book that cannot be played have nowhere to go to', () async {
    final id = await addFolderBook(db, clock);
    await mark(id, 0, 1000);
    await mark(id, 2, 1000);
    await (db.update(db.mediaFiles)..where((f) => f.bookId.equals(id))).write(
      const MediaFilesCompanion(durationMs: Value(null)),
    );

    final shown = await bookmarksOf(id);
    expect([for (final b in shown) b.globalPositionMs], [null, null]);
    expect([for (final b in shown) b.chapterTitle], ['Opening', 'End']);
  });

  test(
    'update by themselves as they are added, renamed, noted and deleted',
    () async {
      final id = await addFolderBook(db, clock);
      final shown = watch(id);
      Future<List<(String?, String?)>> nextText() async => [
        for (final b in await next(shown)) (b.title, b.note),
      ];

      expect(await nextText(), isEmpty);
      final bookmark = await mark(id, 1, 60000);
      expect(await nextText(), [(null, null)]);
      await renameBookmark(db, bookmark, 'Named');
      expect(await nextText(), [('Named', null)]);
      await setBookmarkNote(db, bookmark, 'Noted');
      expect(await nextText(), [('Named', 'Noted')]);
      await deleteBookmark(db, bookmark);
      expect(await nextText(), isEmpty);
    },
  );

  test('update by themselves when their chapter is removed', () async {
    final id = await addFolderBook(db, clock);
    await mark(id, 1, 60000);
    final shown = watch(id);
    expect([for (final b in await next(shown)) b.removedFromSource], [false]);

    await markRemoved((await chapterIdsOf(db, id))[1]);
    expect([for (final b in await next(shown)) b.removedFromSource], [true]);
  });
}
