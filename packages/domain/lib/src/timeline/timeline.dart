import 'dart:math' as math;

import 'positions.dart';
import 'timeline_input.dart';

/// Milliseconds of slack a chapter is allowed before it counts as listened.
///
/// §4.5: a chapter counts as listened when its position reaches its duration minus the larger of
/// 30 seconds or 3 percent, so chapters are not left stuck at "99%" by closing credits.
///
/// Note the consequence for very short chapters: at 30 seconds or less the threshold is zero, so
/// merely starting such a chapter marks it listened. That is the rule as specified.
int listenedThresholdMs(int chapterDurationMs) {
  final slack = math.max(30000, chapterDurationMs * 3 ~/ 100);
  return math.max(0, chapterDurationMs - slack);
}

/// The computed map between a book's chapters, its physical files, and global time.
///
/// Immutable and cheap to rebuild. §4.5 says the Timeline is never stored: when a file's duration
/// is refined, build a new one. Chapter positions stay valid across that rebuild, which is the
/// entire reason progress is persisted chapter-relative.
final class Timeline {
  Timeline._({
    required Map<int, TimelineFile> fileById,
    required Map<int, List<TimelineMarker>> markersByFile,
    required List<TimelineChapter> chapters,
    required List<QueueItem> queue,
    required List<_Span> spans,
    required List<int> chapterStartMs,
    required List<int> chapterEndMs,
    required List<int> itemStartMs,
    required List<bool> chapterIsEstimate,
    required Map<int, int> chapterIndexById,
    required List<NavigationEntry> navigation,
  }) : _fileById = fileById,
       _markersByFile = markersByFile,
       _chapters = chapters,
       queue = List.unmodifiable(queue),
       _spans = spans,
       _chapterStartMs = chapterStartMs,
       _chapterEndMs = chapterEndMs,
       _itemStartMs = itemStartMs,
       _chapterIsEstimate = chapterIsEstimate,
       _chapterIndexById = chapterIndexById,
       navigation = List.unmodifiable(navigation);

  /// Builds a Timeline, validating that the inputs describe a coherent book.
  ///
  /// [markersByFile] holds embedded markers keyed by file id, as probed from the files. They are
  /// presented as virtual chapters only when the book has exactly one source chapter laid out on
  /// a single segment; otherwise they are ignored, as §4.5 specifies.
  ///
  /// Throws [InvalidTimelineException] if the inputs are inconsistent.
  factory Timeline.build({
    required List<TimelineFile> files,
    required List<TimelineChapter> chapters,
    Map<int, List<TimelineMarker>> markersByFile = const {},
  }) {
    if (chapters.isEmpty) {
      throw const InvalidTimelineException('a book needs at least one chapter');
    }

    final fileById = <int, TimelineFile>{};
    for (final f in files) {
      if (f.durationMs < 0) {
        throw InvalidTimelineException('file ${f.id} has a negative duration');
      }
      if (fileById.containsKey(f.id)) {
        throw InvalidTimelineException('file ${f.id} appears twice');
      }
      fileById[f.id] = f;
    }

    final queue = <QueueItem>[];
    final itemStartMs = <int>[];
    final spans = <_Span>[];
    final chapterStartMs = <int>[];
    final chapterEndMs = <int>[];
    final chapterIsEstimate = <bool>[];
    final chapterIndexById = <int, int>{};
    var global = 0;

    for (var ci = 0; ci < chapters.length; ci++) {
      final chapter = chapters[ci];
      if (chapterIndexById.containsKey(chapter.id)) {
        throw InvalidTimelineException('chapter ${chapter.id} appears twice');
      }
      if (chapter.segments.isEmpty) {
        throw InvalidTimelineException('chapter ${chapter.id} has no segments');
      }
      chapterIndexById[chapter.id] = ci;
      chapterStartMs.add(global);
      var estimate = false;

      for (final segment in chapter.segments) {
        final file = fileById[segment.fileId];
        if (file == null) {
          throw InvalidTimelineException(
            'chapter ${chapter.id} refers to unknown file ${segment.fileId}',
          );
        }
        final end = segment.endMs ?? file.durationMs;
        if (segment.startMs < 0) {
          throw InvalidTimelineException(
            'chapter ${chapter.id} has a segment starting before its file does',
          );
        }
        if (end > file.durationMs) {
          throw InvalidTimelineException(
            'chapter ${chapter.id} has a segment ending at ${end}ms, beyond the '
            '${file.durationMs}ms of file ${file.id}',
          );
        }
        if (segment.startMs >= end) {
          throw InvalidTimelineException(
            'chapter ${chapter.id} has an empty segment in file ${file.id}',
          );
        }
        estimate = estimate || file.durationIsEstimate;

        final previous = queue.isEmpty ? null : queue.last;
        if (previous != null &&
            previous.fileId == segment.fileId &&
            previous.clipEndMs == segment.startMs) {
          // Contiguous with the previous segment in the same file: extend the item.
          queue[queue.length - 1] = QueueItem(
            fileId: previous.fileId,
            clipStartMs: previous.clipStartMs,
            clipEndMs: end,
            endsAtFileEnd: end == file.durationMs,
          );
        } else {
          queue.add(
            QueueItem(
              fileId: segment.fileId,
              clipStartMs: segment.startMs,
              clipEndMs: end,
              endsAtFileEnd: end == file.durationMs,
            ),
          );
          itemStartMs.add(global);
        }

        spans.add(
          _Span(
            globalStartMs: global,
            chapterIndex: ci,
            itemIndex: queue.length - 1,
          ),
        );
        global += end - segment.startMs;
      }

      chapterEndMs.add(global);
      chapterIsEstimate.add(estimate);
    }

    final navigation =
        _markerNavigation(chapters, fileById, markersByFile, global) ??
        [
          for (var ci = 0; ci < chapters.length; ci++)
            ChapterEntry(
              chapterId: chapters[ci].id,
              title: chapters[ci].title,
              startMs: chapterStartMs[ci],
              endMs: chapterEndMs[ci],
            ),
        ];

    return Timeline._(
      fileById: Map.unmodifiable(fileById),
      // Kept, like the files and chapters, so that a learned duration can rebuild the book.
      markersByFile: Map.unmodifiable({
        for (final MapEntry(:key, :value) in markersByFile.entries)
          key: List<TimelineMarker>.unmodifiable(value),
      }),
      chapters: List.unmodifiable(chapters),
      queue: queue,
      spans: List.unmodifiable(spans),
      chapterStartMs: List.unmodifiable(chapterStartMs),
      chapterEndMs: List.unmodifiable(chapterEndMs),
      itemStartMs: List.unmodifiable(itemStartMs),
      chapterIsEstimate: List.unmodifiable(chapterIsEstimate),
      chapterIndexById: Map.unmodifiable(chapterIndexById),
      navigation: navigation,
    );
  }

  final Map<int, TimelineFile> _fileById;
  final Map<int, List<TimelineMarker>> _markersByFile;
  final List<TimelineChapter> _chapters;
  final List<_Span> _spans;
  final List<int> _chapterStartMs;
  final List<int> _chapterEndMs;
  final List<int> _itemStartMs;
  final List<bool> _chapterIsEstimate;
  final Map<int, int> _chapterIndexById;

  /// What to load into the playback engine, in order.
  final List<QueueItem> queue;

  /// What the user navigates by: real chapters, or embedded markers presented as virtual
  /// chapters. Always covers the whole book without gaps.
  final List<NavigationEntry> navigation;

  /// Length of the whole book.
  int get totalDurationMs => _chapterEndMs.last;

  /// True if any part of the book's length rests on an estimated file duration.
  bool get isEstimate => _chapterIsEstimate.contains(true);

  /// Chapter ids in playback order.
  List<int> get chapterIds => [for (final c in _chapters) c.id];

  /// The source's last chapter, whose completion finishes the book.
  int get lastChapterId => _chapters.last.id;

  int chapterDurationMs(int chapterId) {
    final ci = _chapterIndex(chapterId);
    return _chapterEndMs[ci] - _chapterStartMs[ci];
  }

  /// Global start and exclusive end of a chapter.
  ({int startMs, int endMs}) chapterRange(int chapterId) {
    final ci = _chapterIndex(chapterId);
    return (startMs: _chapterStartMs[ci], endMs: _chapterEndMs[ci]);
  }

  /// True if this chapter's length rests on an estimated file duration.
  bool chapterDurationIsEstimate(int chapterId) =>
      _chapterIsEstimate[_chapterIndex(chapterId)];

  /// File [fileId] as this Timeline was built from it, including whether its duration is an
  /// estimate.
  ///
  /// Throws [ArgumentError] if the book has no such file.
  TimelineFile file(int fileId) =>
      _fileById[fileId] ??
      (throw ArgumentError.value(fileId, 'fileId', 'not in this book'));

  /// This book again, with file [fileId]'s duration learned to be [durationMs] and no longer an
  /// estimate.
  ///
  /// §4.5: durations are estimated until known and refined as files load. A Timeline is immutable,
  /// so a refinement is a new one, built from the same chapters, files and markers as this one. As
  /// the class documentation says, chapter positions carry over while global positions after the
  /// file shift.
  ///
  /// Throws [ArgumentError] if the book has no such file, and [InvalidTimelineException] if the
  /// book's layout cannot fit the learned duration, such as a segment that ends at an explicit
  /// offset beyond it.
  Timeline withLearnedDuration(int fileId, int durationMs) {
    file(fileId);
    return Timeline.build(
      files: [
        for (final f in _fileById.values)
          f.id == fileId ? TimelineFile(id: fileId, durationMs: durationMs) : f,
      ],
      chapters: _chapters,
      markersByFile: _markersByFile,
    );
  }

  // Conversions. Global positions outside the book are clamped into it, as are offsets past the
  // end of a chapter or item: a stale position should land somewhere sensible, not throw.

  /// Global position of a chapter position.
  int globalOf(ChapterPosition position) {
    final ci = _chapterIndex(position.chapterId);
    final start = _chapterStartMs[ci];
    return start + _clamp(position.offsetMs, 0, _chapterEndMs[ci] - start);
  }

  /// Chapter position at a global position. A position exactly on a boundary belongs to the chapter
  /// that begins there; the very end of the book belongs to the last chapter.
  ChapterPosition chapterPositionAt(int globalMs) {
    final g = _clamp(globalMs, 0, totalDurationMs);
    final ci = _spans[_spanIndexAt(g)].chapterIndex;
    return ChapterPosition(
      chapterId: _chapters[ci].id,
      offsetMs: g - _chapterStartMs[ci],
    );
  }

  /// Engine position at a global position.
  QueuePosition queuePositionAt(int globalMs) {
    final g = _clamp(globalMs, 0, totalDurationMs);
    final ii = _spans[_spanIndexAt(g)].itemIndex;
    return QueuePosition(itemIndex: ii, offsetMs: g - _itemStartMs[ii]);
  }

  /// Global position of an engine position, such as one reported by the engine's position stream.
  ///
  /// Throws [RangeError] if the item index is not in the queue.
  int globalOfQueue(QueuePosition position) {
    RangeError.checkValidIndex(position.itemIndex, queue, 'itemIndex');
    final item = queue[position.itemIndex];
    return _itemStartMs[position.itemIndex] +
        _clamp(position.offsetMs, 0, item.durationMs);
  }

  /// Chapter position of an engine position. This is how the progress store turns what the engine
  /// reports into what gets persisted.
  ChapterPosition chapterPositionOfQueue(QueuePosition position) =>
      chapterPositionAt(globalOfQueue(position));

  /// Engine position of a chapter position. This is how a saved position is resumed.
  QueuePosition queuePositionOfChapter(ChapterPosition position) =>
      queuePositionAt(globalOf(position));

  /// Absolute offset into the underlying file, for engines that seek in file coordinates.
  int fileOffsetOf(QueuePosition position) {
    RangeError.checkValidIndex(position.itemIndex, queue, 'itemIndex');
    final item = queue[position.itemIndex];
    return item.clipStartMs + _clamp(position.offsetMs, 0, item.durationMs);
  }

  /// Time left in the book from a global position.
  int remainingMs(int globalMs) =>
      totalDurationMs - _clamp(globalMs, 0, totalDurationMs);

  /// The navigation entry containing a global position.
  NavigationEntry navigationEntryAt(int globalMs) {
    final g = _clamp(globalMs, 0, totalDurationMs);
    if (g >= totalDurationMs) return navigation.last;
    var lo = 0;
    var hi = navigation.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (navigation[mid].startMs <= g) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return navigation[lo];
  }

  /// §4.5 listened rule applied to a position.
  bool isChapterListened(ChapterPosition position) =>
      position.offsetMs >=
      listenedThresholdMs(chapterDurationMs(position.chapterId));

  /// §4.5: a book is finished when its last chapter is listened.
  bool isBookFinished(ChapterPosition position) =>
      position.chapterId == lastChapterId && isChapterListened(position);

  int _chapterIndex(int chapterId) {
    final ci = _chapterIndexById[chapterId];
    if (ci == null) {
      throw ArgumentError.value(chapterId, 'chapterId', 'not in this book');
    }
    return ci;
  }

  /// Index of the span containing [g], which must already be clamped into the book.
  int _spanIndexAt(int g) {
    if (g >= totalDurationMs) return _spans.length - 1;
    var lo = 0;
    var hi = _spans.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_spans[mid].globalStartMs <= g) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  static int _clamp(int value, int lower, int upper) =>
      math.min(math.max(value, lower), upper);

  /// Builds marker navigation when §4.5's condition holds, or returns null when it does not.
  static List<NavigationEntry>? _markerNavigation(
    List<TimelineChapter> chapters,
    Map<int, TimelineFile> fileById,
    Map<int, List<TimelineMarker>> markersByFile,
    int totalMs,
  ) {
    if (chapters.length != 1 || chapters.single.segments.length != 1) {
      return null;
    }
    final chapter = chapters.single;
    final segment = chapter.segments.single;
    final markers = markersByFile[segment.fileId];
    if (markers == null || markers.isEmpty) return null;

    final sorted = [...markers]..sort((a, b) => a.startMs.compareTo(b.startMs));
    final points = <({int startMs, String title})>[];
    for (final m in sorted) {
      // Markers are file offsets; the chapter may be clipped out of the middle of its file.
      final g = m.startMs - segment.startMs;
      if (g < 0 || g >= totalMs) continue;
      if (points.isNotEmpty && points.last.startMs == g) continue;
      points.add((startMs: g, title: m.title));
    }
    if (points.isEmpty) return null;
    if (points.first.startMs != 0) {
      // Whatever precedes the first marker still needs an entry, or navigation has a hole.
      points.insert(0, (startMs: 0, title: chapter.title));
    }

    return [
      for (var i = 0; i < points.length; i++)
        MarkerEntry(
          title: points[i].title,
          startMs: points[i].startMs,
          endMs: i + 1 < points.length ? points[i + 1].startMs : totalMs,
        ),
    ];
  }
}

/// One segment's place in global time.
final class _Span {
  const _Span({
    required this.globalStartMs,
    required this.chapterIndex,
    required this.itemIndex,
  });

  final int globalStartMs;
  final int chapterIndex;
  final int itemIndex;
}
