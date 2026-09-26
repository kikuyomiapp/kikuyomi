/// What has been listened to, and letting go of it (§4.3, §6.4).
///
/// `listening_session` has been filled in since the coordinator learned to record one: every
/// play-to-pause span becomes a row, split whenever the chapter, the speed or the position jumps, so
/// that each row describes a stretch actually heard. Nothing has ever read them back. This does.
///
/// **A session outlives the chapter it was in.** `chapter_id` is nullable and set to null when a
/// chapter is purged, because §4.4's "keep while it carries user data" rule covers progress,
/// bookmarks and downloads — not history. So a chapter title may be missing from an entry whose book
/// is still perfectly present, and the screen has to say something sensible rather than skip the row.
library;

import 'package:drift/drift.dart';

import '../database/database.dart';
import 'watch_tables.dart';

/// One stretch of listening, as a history screen shows it.
final class HistoryEntry {
  const HistoryEntry({
    required this.sessionId,
    required this.bookId,
    required this.bookTitle,
    required this.startedAt,
    required this.endedAt,
    required this.startGlobalMs,
    required this.endGlobalMs,
    required this.speed,
    this.chapterTitle,
    this.coverFileName,
  });

  /// The row's own id, which is what deleting one entry needs: a book may have many, and two of them
  /// may be in the same chapter minutes apart.
  final int sessionId;

  final int bookId;
  final String bookTitle;

  /// The chapter this stretch was in, or null once that chapter has been purged from the source.
  final String? chapterTitle;

  /// The book's cover in the covers folder, or null for a book without one.
  final String? coverFileName;

  final DateTime startedAt;
  final DateTime endedAt;
  final int startGlobalMs;
  final int endGlobalMs;

  /// The speed this stretch was heard at, which is why it is a stretch of its own: the recorder
  /// splits a session when the speed changes so that each row's figure is true for its whole length.
  final double speed;

  /// Wall-clock time spent listening.
  Duration get listened => endedAt.difference(startedAt);

  /// How much of the book it covered. At 2x this is about twice [listened].
  Duration get covered => Duration(milliseconds: endGlobalMs - startGlobalMs);
}

/// Everything listened to, newest first, watched (§6.4).
///
/// [limit] bounds it because history grows for ever and a screen shows a few days of it. The stream
/// emits again whenever a session is recorded or deleted, and whenever a book is renamed, so a
/// listener watching the screen while a book plays sees the entry appear.
Stream<List<HistoryEntry>> watchListeningHistory(
  KikuyomiDatabase db, {
  int limit = 500,
}) => watchTables(db, [
  db.listeningSessions,
  db.books,
  db.chapters,
], () => _readHistory(db, limit: limit));

Future<List<HistoryEntry>> _readHistory(
  KikuyomiDatabase db, {
  required int limit,
}) async {
  final query =
      db.select(db.listeningSessions).join([
        innerJoin(db.books, db.books.id.equalsExp(db.listeningSessions.bookId)),
        // Left, because the chapter may have been purged while the history stays.
        leftOuterJoin(
          db.chapters,
          db.chapters.id.equalsExp(db.listeningSessions.chapterId),
        ),
      ])..orderBy([
        OrderingTerm.desc(db.listeningSessions.startedAt),
        OrderingTerm.desc(db.listeningSessions.id),
      ]);
  query.limit(limit);

  return [
    for (final row in await query.get())
      _entryOf(
        row.readTable(db.listeningSessions),
        row.readTable(db.books),
        row.readTableOrNull(db.chapters),
      ),
  ];
}

HistoryEntry _entryOf(
  ListeningSessionRow session,
  BookRow book,
  ChapterRow? chapter,
) => HistoryEntry(
  sessionId: session.id,
  bookId: book.id,
  bookTitle: book.title,
  chapterTitle: chapter?.title,
  coverFileName: book.coverLocalPath,
  startedAt: session.startedAt,
  endedAt: session.endedAt,
  startGlobalMs: session.startGlobalMs,
  endGlobalMs: session.endGlobalMs,
  speed: session.speed,
);

/// Forgets one entry.
Future<void> deleteHistoryEntry(KikuyomiDatabase db, int sessionId) =>
    (db.delete(
      db.listeningSessions,
    )..where((s) => s.id.equals(sessionId))).go();

/// Forgets everything recorded for book [bookId], and says how many entries went.
///
/// The listener's own book stays, and so does their progress in it: history is a record of when
/// something was heard, not the fact of having heard it (§4.5 keeps that in `playback_state` and the
/// listened flags).
Future<int> deleteBookHistory(KikuyomiDatabase db, int bookId) => (db.delete(
  db.listeningSessions,
)..where((s) => s.bookId.equals(bookId))).go();

/// Forgets all of it, and says how many entries went.
Future<int> clearListeningHistory(KikuyomiDatabase db) =>
    db.delete(db.listeningSessions).go();
