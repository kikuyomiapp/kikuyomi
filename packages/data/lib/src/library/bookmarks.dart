import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import '../playback/stored_playback.dart';
import 'watch_tables.dart';

/// A bookmark as the player's list of bookmarks shows it.
///
/// A bookmark is stored the way progress is (§4.5): a chapter and an offset into it, never a global
/// position. The global position here is worked out afresh from the book's Timeline every time the
/// list loads, so when a file's estimated duration is refined, the bookmarks after it move with it.
final class BookmarkOverview {
  const BookmarkOverview({
    required this.bookmarkId,
    required this.bookId,
    required this.chapterId,
    required this.chapterPositionMs,
    required this.title,
    required this.note,
    required this.createdAt,
    required this.chapterTitle,
    required this.globalPositionMs,
    required this.removedFromSource,
  });

  final int bookmarkId;
  final int bookId;

  /// The chapter the bookmark is anchored to. With [chapterPositionMs], the truth, as for progress.
  final int chapterId;

  /// How far into its chapter the bookmark is.
  final int chapterPositionMs;

  /// What the listener named the bookmark, or null for one they have not named.
  final String? title;

  /// The listener's note, or null for none.
  final String? note;

  final DateTime createdAt;

  /// The title of the chapter the bookmark is in. For a single file with embedded markers it is the
  /// marker's title, since §4.5 presents those markers as the book's chapters.
  final String chapterTitle;

  /// Where the bookmark is in the book as the player plays it, or null where it has no place there:
  /// its chapter was removed from the source or has no layout yet, or the book cannot be played. See
  /// [watchBookmarks]. A bookmark without one cannot be gone to.
  final int? globalPositionMs;

  /// True when the source no longer reports the bookmark's chapter. §4.4 keeps such a chapter, marked
  /// removed, for as long as a bookmark holds it, and the bookmark stays in the list with it.
  final bool removedFromSource;
}

/// The bookmarks of book [bookId] in playing order, emitting again whenever one of them changes or
/// anything their places are worked out from does.
///
/// Playing order is the source order of their chapters, then their offsets into them, then the order
/// they were made in. Where bookmarks have global positions it is the order of those, and it keeps a
/// bookmark with none where its chapter was rather than moving it to one end of the list.
///
/// A bookmark whose chapter the source no longer reports is listed all the same, marked as such, with
/// no global position. The player's Timeline leaves such a chapter out even while its layout is still
/// stored, so the book being played has no place to go to: going there would mean playing a chapter
/// the book no longer has. A chapter the source still reports but that has no layout yet, and every
/// chapter of a book that cannot be played yet, has no place for the same reason, without the mark.
///
/// It watches the tables the Timeline is built from, as a book's details do. Every progress save
/// writes to the chapters table, which records each chapter's last position, so the list loads again
/// then too; for a book with no bookmarks that costs a single query.
Stream<List<BookmarkOverview>> watchBookmarks(
  KikuyomiDatabase db,
  int bookId,
) => watchTables(db, [
  db.bookmarks,
  db.chapters,
  db.chapterSegments,
  db.mediaFiles,
], () => _loadBookmarks(db, bookId));

/// Adds a bookmark to book [bookId] at [position], and returns its id.
///
/// It is anchored to the chapter and offset, never to a global position (§4.5), so it stays at the
/// same place in its chapter when a duration is refined, and when a single file's embedded markers are
/// retagged. A [title] or [note] that is blank is stored as none, and either is trimmed.
///
/// Throws [ArgumentError] when [position] is not in one of the book's chapters, or is before the start
/// of its chapter.
Future<int> addBookmark(
  KikuyomiDatabase db, {
  required int bookId,
  required ChapterPosition position,
  required Clock clock,
  String? title,
  String? note,
}) async {
  if (position.offsetMs < 0) {
    throw ArgumentError.value(
      position,
      'position',
      'is before the start of its chapter',
    );
  }
  return db.transaction(() async {
    final chapter =
        await (db.select(db.chapters)..where(
              (c) => c.id.equals(position.chapterId) & c.bookId.equals(bookId),
            ))
            .getSingleOrNull();
    if (chapter == null) {
      throw ArgumentError.value(position, 'position', 'is not in book $bookId');
    }
    return db
        .into(db.bookmarks)
        .insert(
          BookmarksCompanion(
            bookId: Value(bookId),
            chapterId: Value(position.chapterId),
            positionMs: Value(position.offsetMs),
            title: Value(_textOrNone(title)),
            note: Value(_textOrNone(note)),
            createdAt: Value(clock.now()),
          ),
        );
  });
}

/// Names bookmark [bookmarkId] [title], trimmed, or takes its name away when [title] is null or blank.
/// Does nothing for a bookmark that does not exist.
Future<void> renameBookmark(
  KikuyomiDatabase db,
  int bookmarkId,
  String? title,
) async {
  await (db.update(db.bookmarks)..where((b) => b.id.equals(bookmarkId))).write(
    BookmarksCompanion(title: Value(_textOrNone(title))),
  );
}

/// Replaces the note of bookmark [bookmarkId] with [note], trimmed, or takes its note away when [note]
/// is null or blank. Does nothing for a bookmark that does not exist.
Future<void> setBookmarkNote(
  KikuyomiDatabase db,
  int bookmarkId,
  String? note,
) async {
  await (db.update(db.bookmarks)..where((b) => b.id.equals(bookmarkId))).write(
    BookmarksCompanion(note: Value(_textOrNone(note))),
  );
}

/// Deletes bookmark [bookmarkId]. Does nothing for a bookmark that does not exist.
///
/// Only the bookmark goes. Its chapter is left as it is, even one the source no longer reports that
/// §4.4 kept only because it held user data.
Future<void> deleteBookmark(KikuyomiDatabase db, int bookmarkId) async {
  await (db.delete(db.bookmarks)..where((b) => b.id.equals(bookmarkId))).go();
}

/// Puts [bookmark] back as it was before it was deleted, for undoing the deletion.
///
/// It comes back whole: the same id, chapter, offset, name, note and creation time. So it returns to
/// its place in the list, and to anything that tells bookmarks apart by id or by creation time it is
/// the same bookmark as before. A bookmark that is still there is left as it is.
///
/// Fails if its chapter has since left the database altogether, which the schema refuses for a chapter
/// that holds a bookmark, but not for one whose last bookmark was just deleted.
Future<void> restoreBookmark(
  KikuyomiDatabase db,
  BookmarkOverview bookmark,
) async {
  // OR IGNORE applies to the primary key only. SQLite never lets it pass over a foreign key, so a
  // chapter that has gone still fails the insert.
  await db
      .into(db.bookmarks)
      .insert(
        BookmarksCompanion(
          id: Value(bookmark.bookmarkId),
          bookId: Value(bookmark.bookId),
          chapterId: Value(bookmark.chapterId),
          positionMs: Value(bookmark.chapterPositionMs),
          title: Value(bookmark.title),
          note: Value(bookmark.note),
          createdAt: Value(bookmark.createdAt),
        ),
        mode: InsertMode.insertOrIgnore,
      );
}

typedef _Mark = ({BookmarkRow bookmark, ChapterRow chapter});

Future<List<BookmarkOverview>> _loadBookmarks(
  KikuyomiDatabase db,
  int bookId,
) async {
  final rows = await (db.select(db.bookmarks).join([
    innerJoin(db.chapters, db.chapters.id.equalsExp(db.bookmarks.chapterId)),
  ])..where(db.bookmarks.bookId.equals(bookId))).get();
  if (rows.isEmpty) return const [];

  final marks = <_Mark>[
    for (final row in rows)
      (
        bookmark: row.readTable(db.bookmarks),
        chapter: row.readTable(db.chapters),
      ),
  ]..sort(_inPlayingOrder);

  final timeline = await _timelineOf(db, bookId);
  final onTimeline = {...?timeline?.chapterIds};
  return [
    for (final (:bookmark, :chapter) in marks)
      _overview(
        bookmark,
        chapter,
        onTimeline.contains(chapter.id) ? timeline : null,
      ),
  ];
}

/// [bookmark] in [chapter], placed on [timeline], or on none when its chapter is not on the Timeline.
BookmarkOverview _overview(
  BookmarkRow bookmark,
  ChapterRow chapter,
  Timeline? timeline,
) {
  final global = timeline?.globalOf(
    ChapterPosition(chapterId: chapter.id, offsetMs: bookmark.positionMs),
  );
  // Only a marker is named by the entry the position falls in. A chapter entry is not, because a
  // bookmark at the very end of its chapter falls at the start of the next one; its own chapter's
  // title is the right one.
  final entry = global == null ? null : timeline?.navigationEntryAt(global);
  return BookmarkOverview(
    bookmarkId: bookmark.id,
    bookId: bookmark.bookId,
    chapterId: chapter.id,
    chapterPositionMs: bookmark.positionMs,
    title: bookmark.title,
    note: bookmark.note,
    createdAt: bookmark.createdAt,
    chapterTitle: entry is MarkerEntry ? entry.title : chapter.title,
    globalPositionMs: global,
    removedFromSource: chapter.removedFromSource,
  );
}

/// Source order of chapters, as the Timeline lays them out, then the offset into the chapter, then the
/// order bookmarks were made in. Times are compared here rather than in SQL, where they are text with
/// their UTC offset and sort wrongly across a daylight-saving change.
int _inPlayingOrder(_Mark a, _Mark b) => [
  a.chapter.sourceIndex.compareTo(b.chapter.sourceIndex),
  a.chapter.id.compareTo(b.chapter.id),
  a.bookmark.positionMs.compareTo(b.bookmark.positionMs),
  a.bookmark.createdAt.compareTo(b.bookmark.createdAt),
  a.bookmark.id.compareTo(b.bookmark.id),
].firstWhere((order) => order != 0, orElse: () => 0);

/// The Timeline the player would build for the book, or null while it cannot be played.
Future<Timeline?> _timelineOf(KikuyomiDatabase db, int bookId) async {
  try {
    return (await loadStoredPlayback(db, bookId)).timeline;
  } on UnplayableBookException {
    return null;
  } on InvalidTimelineException {
    return null;
  }
}

/// [text] trimmed, or null when nothing is left of it.
String? _textOrNone(String? text) {
  final trimmed = text?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
