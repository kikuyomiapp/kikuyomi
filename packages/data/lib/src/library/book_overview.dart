import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import '../playback/stored_playback.dart';
import 'watch_tables.dart';

/// A book as its details screen shows it.
///
/// Named apart from `BookDetails`, which is what a source provides for §4.4's merge. This is what
/// the database holds about a book once it is in the library, progress included.
final class BookOverview {
  const BookOverview({
    required this.bookId,
    required this.title,
    required this.authors,
    required this.narrators,
    required this.totalDurationMs,
    required this.inLibrary,
    required this.chapters,
    required this.markers,
    required this.progress,
  });

  final int bookId;
  final String title;

  /// In credit order.
  final List<String> authors;

  /// In credit order.
  final List<String> narrators;

  /// The length of the whole book, or null while it is unknown.
  final int? totalDurationMs;

  /// False once the book has been taken out of the library. Its progress is kept all the same.
  final bool inLibrary;

  /// In source order, leaving out chapters the source no longer reports.
  final List<ChapterOverview> chapters;

  /// The embedded markers of a single file, which §4.5 presents as the book's chapters; empty for
  /// any other book. Where there are markers they are what to list, and [chapters] holds only the
  /// one chapter that spans the file.
  final List<MarkerOverview> markers;

  /// Where the listener is, or null for a book never started.
  final BookProgress? progress;
}

final class ChapterOverview {
  const ChapterOverview({
    required this.chapterId,
    required this.title,
    required this.durationMs,
    required this.listened,
    required this.current,
  });

  final int chapterId;
  final String title;

  /// Worked out from the files where the chapter's layout is known, as the player's Timeline does;
  /// otherwise what the source said, or null.
  final int? durationMs;

  /// §4.5: the chapter is marked listened, or the listener has been in it and reached its duration
  /// less the larger of 30 seconds or 3 percent.
  final bool listened;

  /// True for the chapter the saved progress is in.
  final bool current;
}

/// An embedded marker presented as a chapter (§4.5).
final class MarkerOverview {
  const MarkerOverview({
    required this.title,
    required this.startMs,
    required this.endMs,
    required this.listened,
    required this.current,
  });

  final String title;

  /// Where the marker's stretch starts in the book, inclusive.
  final int startMs;

  /// Where it ends, exclusive.
  final int endMs;

  /// §4.5's listened rule applied to the marker's own stretch.
  final bool listened;

  /// True for the marker the saved progress is in.
  final bool current;

  int get durationMs => endMs - startMs;
}

/// A book's saved progress.
final class BookProgress {
  const BookProgress({
    required this.chapterId,
    required this.chapterPositionMs,
    required this.globalPositionMs,
    required this.lastPlayedAt,
    required this.finished,
  });

  /// Progress is stored chapter-relative (§4.5): this chapter and offset are the truth.
  final int chapterId;
  final int chapterPositionMs;

  /// Derived from the Timeline and cached with the progress, for display.
  final int globalPositionMs;
  final DateTime lastPlayedAt;

  /// §4.5: the position is in the last chapter and that chapter is listened.
  final bool finished;
}

/// The details of book [bookId], emitting again whenever any of them changes, or null while there is
/// no such book.
///
/// Durations and markers come from the same Timeline the player builds, so the details and the
/// player agree. A book that cannot be played yet still has its details, with durations from its
/// chapter rows and no markers.
Stream<BookOverview?> watchBookOverview(KikuyomiDatabase db, int bookId) =>
    watchTables(db, [
      db.books,
      db.bookPeople,
      db.people,
      db.chapters,
      db.chapterSegments,
      db.mediaFiles,
      db.playbackStates,
    ], () => _loadBookOverview(db, bookId));

Future<BookOverview?> _loadBookOverview(KikuyomiDatabase db, int bookId) async {
  final book = await (db.select(
    db.books,
  )..where((b) => b.id.equals(bookId))).getSingleOrNull();
  if (book == null) return null;

  final credits =
      await (db.select(db.bookPeople).join([
              innerJoin(
                db.people,
                db.people.id.equalsExp(db.bookPeople.personId),
              ),
            ])
            ..where(db.bookPeople.bookId.equals(bookId))
            ..orderBy([OrderingTerm.asc(db.bookPeople.ordinal)]))
          .get();
  List<String> credited(ContributorRole role) => [
    for (final row in credits)
      if (row.readTable(db.bookPeople).role == role)
        row.readTable(db.people).name,
  ];

  final chapters =
      await (db.select(db.chapters)
            ..where(
              (c) =>
                  c.bookId.equals(bookId) & c.removedFromSource.equals(false),
            )
            ..orderBy([
              (c) => OrderingTerm.asc(c.sourceIndex),
              (c) => OrderingTerm.asc(c.id),
            ]))
          .get();

  final state = await (db.select(
    db.playbackStates,
  )..where((p) => p.bookId.equals(bookId))).getSingleOrNull();

  final timeline = await _timelineOf(db, bookId);
  final onTimeline = {...?timeline?.chapterIds};

  int? durationOf(ChapterRow chapter) =>
      timeline != null && onTimeline.contains(chapter.id)
      ? timeline.chapterDurationMs(chapter.id)
      : chapter.durationMs;

  // Where the listener last was in a chapter, or null if they have never been in it. A chapter
  // never reached also sits at zero, which for a chapter of 30 seconds or less already meets its
  // threshold, so zero counts only where the saved progress is.
  int? reachedOffset(ChapterRow chapter) {
    if (state != null && state.chapterId == chapter.id) {
      return state.chapterPositionMs;
    }
    return chapter.lastPositionMs > 0 ? chapter.lastPositionMs : null;
  }

  var markers = const <MarkerOverview>[];
  final markerChapter = timeline == null
      ? null
      : chapters.where((c) => c.id == timeline.lastChapterId).firstOrNull;
  if (timeline != null && markerChapter != null) {
    final offset = reachedOffset(markerChapter);
    // The Timeline presents markers only for a book of one chapter, so its offsets are the book's.
    final here = state != null && state.chapterId == markerChapter.id
        ? timeline.navigationEntryAt(state.chapterPositionMs)
        : null;
    markers = [
      for (final entry in timeline.navigation.whereType<MarkerEntry>())
        MarkerOverview(
          title: entry.title,
          startMs: entry.startMs,
          endMs: entry.endMs,
          listened:
              markerChapter.isListened ||
              _listened(
                offset,
                startMs: entry.startMs,
                durationMs: entry.durationMs,
              ),
          current: entry == here,
        ),
    ];
  }

  return BookOverview(
    bookId: book.id,
    title: book.title,
    authors: credited(ContributorRole.author),
    narrators: credited(ContributorRole.narrator),
    totalDurationMs: book.totalDurationMs ?? timeline?.totalDurationMs,
    inLibrary: book.inLibrary,
    chapters: [
      for (final chapter in chapters)
        ChapterOverview(
          chapterId: chapter.id,
          title: chapter.title,
          durationMs: durationOf(chapter),
          listened:
              chapter.isListened ||
              _listened(
                reachedOffset(chapter),
                durationMs: durationOf(chapter),
              ),
          current: state?.chapterId == chapter.id,
        ),
    ],
    markers: markers,
    progress: state == null
        ? null
        : BookProgress(
            chapterId: state.chapterId,
            chapterPositionMs: state.chapterPositionMs,
            globalPositionMs: state.globalPositionMs,
            lastPlayedAt: state.updatedAt,
            finished:
                timeline != null &&
                timeline.isBookFinished(
                  ChapterPosition(
                    chapterId: state.chapterId,
                    offsetMs: state.chapterPositionMs,
                  ),
                ),
          ),
  );
}

/// §4.5's listened rule: [offsetMs] has reached the stretch that starts at [startMs] and lasts
/// [durationMs], less the larger of 30 seconds or 3 percent. False where either is unknown.
bool _listened(int? offsetMs, {int startMs = 0, required int? durationMs}) =>
    offsetMs != null &&
    durationMs != null &&
    offsetMs >= startMs + listenedThresholdMs(durationMs);

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
