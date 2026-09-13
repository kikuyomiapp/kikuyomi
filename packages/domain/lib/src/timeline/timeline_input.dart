/// What the Timeline is built from.
///
/// These mirror the persisted layout in docs/architecture.md §4.3: a `media_file` row per physical
/// file, and `chapter_segment` rows describing which stretch of which file each chapter occupies.
/// Nothing here carries a URL; URLs are ephemeral and the Timeline never needs one.
library;

/// A physical audio file, as far as timing is concerned.
final class TimelineFile {
  const TimelineFile({
    required this.id,
    required this.durationMs,
    this.durationIsEstimate = false,
  });

  /// The `media_file` surrogate key.
  final int id;

  /// Best known duration. §4.5: durations are estimated until known and refined as files load.
  final int durationMs;

  /// True while [durationMs] is an estimate rather than a probed value.
  final bool durationIsEstimate;

  @override
  String toString() =>
      'TimelineFile($id, ${durationMs}ms${durationIsEstimate ? ', estimate' : ''})';
}

/// One contiguous stretch of one file that belongs to a chapter.
final class TimelineSegment {
  const TimelineSegment({required this.fileId, this.startMs = 0, this.endMs});

  final int fileId;

  /// Inclusive offset into the file.
  final int startMs;

  /// Exclusive offset into the file, or null for "to the end of the file".
  ///
  /// Null is the common case and the valuable one: a whole-file segment follows its file's
  /// duration automatically when that duration is refined, so nothing has to be rewritten.
  final int? endMs;

  @override
  String toString() =>
      'TimelineSegment(file $fileId, $startMs-${endMs ?? 'end'})';
}

/// A chapter as the source defines it, laid out onto files.
final class TimelineChapter {
  TimelineChapter({
    required this.id,
    required this.title,
    required List<TimelineSegment> segments,
  }) : segments = List.unmodifiable(segments);

  /// The `chapter` surrogate key. Progress is persisted against this.
  final int id;
  final String title;

  /// In playback order.
  final List<TimelineSegment> segments;

  @override
  String toString() =>
      'TimelineChapter($id, "$title", ${segments.length} segments)';
}

/// A chapter marker embedded in a file, such as an M4B chapter.
final class TimelineMarker {
  const TimelineMarker({required this.title, required this.startMs});

  final String title;

  /// Offset into the file that carries the marker, not into the book.
  final int startMs;
}

/// Thrown when the inputs cannot describe a coherent book.
///
/// The data layer is expected to keep segments consistent with file durations, so reaching this
/// means stored data is wrong, not that a user did something unusual.
final class InvalidTimelineException implements Exception {
  const InvalidTimelineException(this.message);

  final String message;

  @override
  String toString() => 'InvalidTimelineException: $message';
}
