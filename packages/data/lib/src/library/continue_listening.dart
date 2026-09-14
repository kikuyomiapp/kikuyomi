import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import '../database/tables.dart';
import 'watch_tables.dart';

/// A started book, as Continue Listening shows it.
final class ContinueListeningBook {
  const ContinueListeningBook({
    required this.bookId,
    required this.title,
    required this.author,
    required this.totalDurationMs,
    required this.globalPositionMs,
    required this.chapterTitle,
    required this.lastPlayedAt,
  });

  final int bookId;
  final String title;

  /// The first credited author, or null for a book credited with none.
  final String? author;

  /// The length of the whole book, or null while it is unknown.
  final int? totalDurationMs;

  /// Where the listener is in the whole book: the global position cached with the progress for
  /// display (§4.3).
  final int globalPositionMs;

  /// The chapter the listener is in. For a single file with embedded markers it is the marker's
  /// title, since §4.5 presents those markers as the book's chapters.
  final String chapterTitle;

  /// When progress was last saved.
  final DateTime lastPlayedAt;
}

/// Continue Listening, which §1.5 calls the most important screen in the app: the books in the
/// library that have been started and not finished, most recently played first.
///
/// `playback_states` is its source of truth (§4.3): a book has been started when it has a row
/// there. It is finished, by §4.5, when that saved position is in its last playable chapter and has
/// reached the chapter's listened threshold, which is the test `Timeline.isBookFinished` makes. So a
/// finished book played again from an earlier chapter comes back.
///
/// The stream emits again whenever anything it shows changes, including every progress save.
Stream<List<ContinueListeningBook>> watchContinueListening(
  KikuyomiDatabase db,
) => watchTables(db, [
  db.playbackStates,
  db.books,
  db.chapters,
  db.chapterSegments,
  db.mediaFiles,
  db.bookPeople,
  db.people,
], () => _loadContinueListening(db));

Future<List<ContinueListeningBook>> _loadContinueListening(
  KikuyomiDatabase db,
) async {
  final isLast = _noOtherPlayableChapter(db, after: true);
  final isFirst = _noOtherPlayableChapter(db, after: false);
  final rows =
      await (db.select(db.playbackStates).join([
              innerJoin(
                db.books,
                db.books.id.equalsExp(db.playbackStates.bookId),
              ),
              innerJoin(
                db.chapters,
                db.chapters.id.equalsExp(db.playbackStates.chapterId),
              ),
            ])
            ..addColumns([isLast, isFirst])
            ..where(db.books.inLibrary.equals(true)))
          .get();
  if (rows.isEmpty) return const [];

  final layouts = await _layouts(db, {
    for (final row in rows) row.readTable(db.chapters).id,
  });
  final authors = await _firstAuthors(db, {
    for (final row in rows) row.readTable(db.books).id,
  });

  final books = <ContinueListeningBook>[];
  for (final row in rows) {
    final state = row.readTable(db.playbackStates);
    final book = row.readTable(db.books);
    final chapter = row.readTable(db.chapters);
    final last = row.read(isLast) ?? false;
    final timeline = _chapterTimeline(
      chapter,
      layouts[chapter.id] ?? const [],
      withMarkers: last && (row.read(isFirst) ?? false),
    );
    final position = ChapterPosition(
      chapterId: chapter.id,
      offsetMs: state.chapterPositionMs,
    );
    // A chapter that cannot be played has no Timeline, and its book stays: opening it is how the
    // listener finds out why it will not play.
    if (last && timeline != null && timeline.isChapterListened(position)) {
      continue;
    }
    books.add(
      ContinueListeningBook(
        bookId: book.id,
        title: book.title,
        author: authors[book.id],
        totalDurationMs: book.totalDurationMs,
        globalPositionMs: state.globalPositionMs,
        chapterTitle:
            timeline?.navigationEntryAt(state.chapterPositionMs).title ??
            chapter.title,
        lastPlayedAt: state.updatedAt,
      ),
    );
  }
  // Sorted here rather than in SQL: times from the system clock are stored as text with their UTC
  // offset, and text order goes wrong across a daylight-saving change.
  books.sort((a, b) {
    final byTime = b.lastPlayedAt.compareTo(a.lastPlayedAt);
    return byTime != 0 ? byTime : b.bookId.compareTo(a.bookId);
  });
  return books;
}

/// True when no other playable chapter of the same book comes after the chapter in the outer query
/// or, when [after] is false, before it, in source order.
///
/// Playable means what `loadStoredPlayback` puts on the Timeline: not removed from the source, and
/// laid out on at least one segment. Asked in SQL, so finding a book's last chapter never loads
/// the chapters of every started book.
Expression<bool> _noOtherPlayableChapter(
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

typedef _Part = ({ChapterSegmentRow segment, MediaFileRow file});

/// The segments of each of [chapterIds], in order, with their files.
Future<Map<int, List<_Part>>> _layouts(
  KikuyomiDatabase db,
  Set<int> chapterIds,
) async {
  final rows =
      await (db.select(db.chapterSegments).join([
              innerJoin(
                db.mediaFiles,
                db.mediaFiles.id.equalsExp(db.chapterSegments.mediaFileId),
              ),
            ])
            ..where(db.chapterSegments.chapterId.isIn(chapterIds))
            ..orderBy([OrderingTerm.asc(db.chapterSegments.ordinal)]))
          .get();
  final layouts = <int, List<_Part>>{};
  for (final row in rows) {
    final segment = row.readTable(db.chapterSegments);
    (layouts[segment.chapterId] ??= []).add((
      segment: segment,
      file: row.readTable(db.mediaFiles),
    ));
  }
  return layouts;
}

/// The first credited author of each of [bookIds] that has one.
Future<Map<int, String>> _firstAuthors(
  KikuyomiDatabase db,
  Set<int> bookIds,
) async {
  final rows =
      await (db.select(db.bookPeople).join([
              innerJoin(
                db.people,
                db.people.id.equalsExp(db.bookPeople.personId),
              ),
            ])
            ..where(
              db.bookPeople.bookId.isIn(bookIds) &
                  db.bookPeople.role.equalsValue(ContributorRole.author),
            )
            ..orderBy([OrderingTerm.asc(db.bookPeople.ordinal)]))
          .get();
  final authors = <int, String>{};
  for (final row in rows) {
    authors.putIfAbsent(
      row.readTable(db.bookPeople).bookId,
      () => row.readTable(db.people).name,
    );
  }
  return authors;
}

/// A Timeline of [chapter] alone, built from its [layout], in which global positions are the
/// chapter's own offsets. Null when the chapter has no layout or a file of unknown length, when it
/// cannot be played anyway.
///
/// Only the chapter the listener is in is built, so a long shelf never loads every book's layout.
/// [withMarkers] hands over the files' embedded markers, and should be true only for a book's one
/// playable chapter: that is when §4.5 presents markers as chapters, and the Timeline cannot see the
/// rest of the book to check.
Timeline? _chapterTimeline(
  ChapterRow chapter,
  List<_Part> layout, {
  required bool withMarkers,
}) {
  if (layout.isEmpty) return null;
  final files = {for (final part in layout) part.file.id: part.file};
  final timelineFiles = [
    for (final file in files.values)
      if (file.durationMs case final durationMs?)
        TimelineFile(
          id: file.id,
          durationMs: durationMs,
          durationIsEstimate: file.durationIsEstimate,
        ),
  ];
  if (timelineFiles.length != files.length) return null;
  try {
    return Timeline.build(
      files: timelineFiles,
      chapters: [
        TimelineChapter(
          id: chapter.id,
          title: chapter.title,
          segments: [
            for (final part in layout)
              TimelineSegment(
                fileId: part.segment.mediaFileId,
                startMs: part.segment.startMs,
                endMs: part.segment.endMs,
              ),
          ],
        ),
      ],
      markersByFile: {
        if (withMarkers)
          for (final file in files.values)
            if (file.embeddedMarkers case final markers?
                when markers.isNotEmpty)
              file.id: markers,
      },
    );
  } on InvalidTimelineException {
    return null;
  }
}
