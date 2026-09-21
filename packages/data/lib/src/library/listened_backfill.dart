/// Working listened state out from saved positions (§4.5), for the chapters that were listened to
/// where nothing recorded it: the library as it was before listened state was recorded, and
/// backups written then.
///
/// Not exported from the package. `backfillListenedChapters` runs it over the whole library, and a
/// restore from an old backup over the chapters it wrote.
library;

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import 'book_queries.dart';

/// Records as listened every chapter whose saved position has reached its listened threshold but
/// that is not yet recorded as listened, among [onlyChapters] when given, and returns how many it
/// recorded. `backfillListenedChapters` describes how positions and durations are read.
///
/// Call it inside a transaction: it reads the positions and writes the flags in several steps.
Future<int> recordListenedFromPositions(
  KikuyomiDatabase db, {
  Set<int>? onlyChapters,
}) async {
  if (onlyChapters != null && onlyChapters.isEmpty) return 0;
  final states = {
    for (final state in await db.select(db.playbackStates).get())
      state.bookId: state,
  };
  // Chapters that have been reached, so could have reached a threshold. [onlyChapters] is applied
  // afterwards rather than in SQL, where a restore of a large library could hold more ids than
  // SQLite allows in one statement.
  final candidates =
      await (db.select(db.chapters)..where(
            (c) =>
                c.isListened.equals(false) &
                (c.lastPositionMs.isBiggerThanValue(0) |
                    c.id.isInQuery(
                      db.selectOnly(db.playbackStates)
                        ..addColumns([db.playbackStates.chapterId]),
                    )),
          ))
          .get();

  final reachedByBook = <int, List<(ChapterRow, int)>>{};
  for (final chapter in candidates) {
    if (onlyChapters != null && !onlyChapters.contains(chapter.id)) continue;
    final state = states[chapter.bookId];
    final offset = state != null && state.chapterId == chapter.id
        ? state.chapterPositionMs
        : chapter.lastPositionMs;
    (reachedByBook[chapter.bookId] ??= []).add((chapter, offset));
  }

  var recorded = 0;
  for (final MapEntry(key: bookId, value: reached) in reachedByBook.entries) {
    final timeline = await timelineOrNone(db, bookId);
    final onTimeline = {...?timeline?.chapterIds};
    for (final (chapter, offsetMs) in reached) {
      final durationMs = timeline != null && onTimeline.contains(chapter.id)
          ? timeline.chapterDurationMs(chapter.id)
          : chapter.durationMs;
      if (durationMs == null || offsetMs < listenedThresholdMs(durationMs)) {
        continue;
      }
      await (db.update(
            db.chapters,
          )..where((c) => c.id.equals(chapter.id) & c.isListened.equals(false)))
          .write(
            ChaptersCompanion(
              isListened: const Value(true),
              listenedAt: Value(chapter.updatedAt),
            ),
          );
      recorded++;
    }
  }
  return recorded;
}
