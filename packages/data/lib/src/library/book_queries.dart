/// Queries the library's read models share: a book's Timeline, and which chapter finishes it.
///
/// Not exported from the package. What each read model shows is its own business; these are how
/// several of them find the same things, so that they agree.
library;

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import '../playback/stored_playback.dart';

/// The Timeline the player would build for book [bookId], or null while it cannot be played.
Future<Timeline?> timelineOrNone(KikuyomiDatabase db, int bookId) async {
  try {
    return (await loadStoredPlayback(db, bookId)).timeline;
  } on UnplayableBookException {
    return null;
  } on InvalidTimelineException {
    return null;
  }
}

/// The last chapter the player plays of each of [bookIds] that has one: the last in source order
/// that is still reported by the source and laid out on at least one segment, which is the chapter
/// `loadStoredPlayback` puts last on the Timeline.
///
/// §4.5: a book is finished when this chapter is listened. A book of which the player can play
/// nothing has no such chapter, and is never finished.
Future<Map<int, ChapterRow>> lastPlayableChapters(
  KikuyomiDatabase db,
  Iterable<int> bookIds,
) async {
  final ids = bookIds.toSet();
  if (ids.isEmpty) return const {};
  final ownSegment = db.alias(db.chapterSegments, 'own_segment');
  final rows =
      await (db.select(db.chapters)..where(
            (c) =>
                c.bookId.isIn(ids) &
                c.removedFromSource.equals(false) &
                existsQuery(
                  db.selectOnly(ownSegment)
                    ..addColumns([ownSegment.chapterId])
                    ..where(ownSegment.chapterId.equalsExp(c.id)),
                ) &
                noOtherPlayableChapter(db, after: true),
          ))
          .get();
  return {for (final chapter in rows) chapter.bookId: chapter};
}

/// True when no other playable chapter of the same book comes after the chapter in the outer query
/// or, when [after] is false, before it, in source order. The outer query selects from
/// `db.chapters` itself, not an alias of it.
///
/// Playable means what `loadStoredPlayback` puts on the Timeline: not removed from the source, and
/// laid out on at least one segment. Asked in SQL, so finding a book's last chapter never loads the
/// chapters of every book asked about.
Expression<bool> noOtherPlayableChapter(
  KikuyomiDatabase db, {
  required bool after,
}) {
  final name = after ? 'later' : 'earlier';
  final other = db.alias(db.chapters, '${name}_chapter');
  final segment = db.alias(db.chapterSegments, '${name}_segment');
  final current = db.chapters;
  final beyond = after
      ? other.sourceIndex.isBiggerThan(current.sourceIndex) |
            (other.sourceIndex.equalsExp(current.sourceIndex) &
                other.id.isBiggerThan(current.id))
      : other.sourceIndex.isSmallerThan(current.sourceIndex) |
            (other.sourceIndex.equalsExp(current.sourceIndex) &
                other.id.isSmallerThan(current.id));
  return notExistsQuery(
    db.selectOnly(other).join([
        innerJoin(
          segment,
          segment.chapterId.equalsExp(other.id),
          useColumns: false,
        ),
      ])
      ..addColumns([other.id])
      ..where(
        other.bookId.equalsExp(current.bookId) &
            other.removedFromSource.equals(false) &
            beyond,
      ),
  );
}
