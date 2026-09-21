// Drift exports a query helper called isNull; nothing here needs it, and hiding it keeps the name
// free for callers.
import 'package:drift/drift.dart' hide isNull;
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';

/// A book as the database hands it to playback.
final class StoredPlayback {
  const StoredPlayback({
    required this.timeline,
    this.resumeFrom,
    this.lastPlayedAt,
    this.speed,
    this.finished = false,
  });

  final Timeline timeline;

  /// §4.5: the Timeline's last chapter is recorded as listened, so the book is finished. The same
  /// test a book's details and Continue Listening make.
  final bool finished;

  /// Where to resume, or null to start from the beginning.
  final ChapterPosition? resumeFrom;

  /// When progress was last saved, from which the caller works out how long the pause was.
  final DateTime? lastPlayedAt;

  /// The book's remembered speed, or null if it has never been changed.
  final double? speed;
}

/// A book whose stored layout cannot be played yet.
///
/// Reaching this means an import or a refresh is incomplete — a file not yet probed, or chapters
/// with no known layout — rather than that the stored data is inconsistent, which the Timeline
/// reports separately as an [InvalidTimelineException].
final class UnplayableBookException implements Exception {
  const UnplayableBookException(this.message);

  final String message;

  @override
  String toString() => 'UnplayableBookException: $message';
}

/// Loads everything needed to play book [bookId]: its Timeline, computed from the stored layout as
/// §4.5 requires rather than stored, and where and how to resume.
///
/// Chapters removed from the source are left out, as are chapters with no layout yet. If the saved
/// position is in a chapter that is no longer playable, playback resumes at the start of the next
/// playable chapter in source order, rather than silently starting the book again; only when no
/// chapter follows is the position given up.
///
/// Throws [ArgumentError] for a book that does not exist, and [UnplayableBookException] when no
/// chapter can be played or a file in the layout has no known duration.
Future<StoredPlayback> loadStoredPlayback(
  KikuyomiDatabase db,
  int bookId,
) async {
  final book = await (db.select(
    db.books,
  )..where((b) => b.id.equals(bookId))).getSingleOrNull();
  if (book == null) {
    throw ArgumentError.value(bookId, 'bookId', 'no such book');
  }

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

  final segments = chapters.isEmpty
      ? const <ChapterSegmentRow>[]
      : await (db.select(db.chapterSegments)
              ..where((s) => s.chapterId.isIn([for (final c in chapters) c.id]))
              ..orderBy([(s) => OrderingTerm.asc(s.ordinal)]))
            .get();
  final segmentsByChapter = <int, List<ChapterSegmentRow>>{};
  for (final segment in segments) {
    (segmentsByChapter[segment.chapterId] ??= []).add(segment);
  }

  final playable = [
    for (final chapter in chapters)
      if (segmentsByChapter.containsKey(chapter.id)) chapter,
  ];
  if (playable.isEmpty) {
    throw UnplayableBookException(
      'book $bookId has no chapter with a known layout',
    );
  }

  final files = await (db.select(
    db.mediaFiles,
  )..where((f) => f.id.isIn({for (final s in segments) s.mediaFileId}))).get();
  final timelineFiles = <TimelineFile>[];
  final markersByFile = <int, List<TimelineMarker>>{};
  for (final file in files) {
    final duration = file.durationMs;
    if (duration == null) {
      throw UnplayableBookException(
        'file "${file.fileKey}" of book $bookId has no known duration',
      );
    }
    timelineFiles.add(
      TimelineFile(
        id: file.id,
        durationMs: duration,
        durationIsEstimate: file.durationIsEstimate,
      ),
    );
    final markers = file.embeddedMarkers;
    if (markers != null && markers.isNotEmpty) markersByFile[file.id] = markers;
  }

  final timeline = Timeline.build(
    files: timelineFiles,
    chapters: [
      for (final chapter in playable)
        TimelineChapter(
          id: chapter.id,
          title: chapter.title,
          segments: [
            for (final segment in segmentsByChapter[chapter.id]!)
              TimelineSegment(
                fileId: segment.mediaFileId,
                startMs: segment.startMs,
                endMs: segment.endMs,
              ),
          ],
        ),
    ],
    markersByFile: markersByFile,
  );

  final state = await (db.select(
    db.playbackStates,
  )..where((p) => p.bookId.equals(bookId))).getSingleOrNull();

  return StoredPlayback(
    timeline: timeline,
    resumeFrom: state == null
        ? null
        : await _resumePosition(db, state, playable),
    lastPlayedAt: state?.updatedAt,
    speed: book.playbackSpeed,
    finished: playable.last.isListened,
  );
}

Future<ChapterPosition?> _resumePosition(
  KikuyomiDatabase db,
  PlaybackStateRow state,
  List<ChapterRow> playable,
) async {
  if (playable.any((c) => c.id == state.chapterId)) {
    return ChapterPosition(
      chapterId: state.chapterId,
      offsetMs: state.chapterPositionMs,
    );
  }
  final saved = await (db.select(
    db.chapters,
  )..where((c) => c.id.equals(state.chapterId))).getSingleOrNull();
  if (saved == null) return null;
  for (final chapter in playable) {
    if (chapter.sourceIndex >= saved.sourceIndex) {
      return ChapterPosition(chapterId: chapter.id, offsetMs: 0);
    }
  }
  return null;
}
