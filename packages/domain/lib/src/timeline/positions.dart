/// The three coordinate systems of §4.5, plus navigation.
///
/// The engine thinks only in queue positions. Progress and the UI think in chapter positions.
/// The scrubber, statistics and "time remaining" think in global milliseconds, which are plain
/// `int`s and have no type of their own.
library;

/// A position inside a chapter. This is what progress is persisted as.
final class ChapterPosition {
  const ChapterPosition({required this.chapterId, required this.offsetMs});

  final int chapterId;

  /// Milliseconds from the start of the chapter.
  final int offsetMs;

  @override
  bool operator ==(Object other) =>
      other is ChapterPosition &&
      other.chapterId == chapterId &&
      other.offsetMs == offsetMs;

  @override
  int get hashCode => Object.hash(chapterId, offsetMs);

  @override
  String toString() => 'ChapterPosition(chapter $chapterId @ ${offsetMs}ms)';
}

/// One item in the playback engine's queue: a physical file, or a clipped stretch of one.
///
/// §6.2: engine queue items are files, not chapters. Consecutive segments that are contiguous in
/// the same file are merged into one item, so a single M4B plays as one item however many
/// chapters it holds, and "next chapter" becomes a seek rather than a queue change.
final class QueueItem {
  const QueueItem({
    required this.fileId,
    required this.clipStartMs,
    required this.clipEndMs,
  });

  final int fileId;

  /// Inclusive offset into the file where this item begins.
  final int clipStartMs;

  /// Exclusive offset into the file where this item ends.
  final int clipEndMs;

  int get durationMs => clipEndMs - clipStartMs;

  /// True when the item is the whole file from its beginning and needs no clipping at the start.
  bool get startsAtFileStart => clipStartMs == 0;

  @override
  bool operator ==(Object other) =>
      other is QueueItem &&
      other.fileId == fileId &&
      other.clipStartMs == clipStartMs &&
      other.clipEndMs == clipEndMs;

  @override
  int get hashCode => Object.hash(fileId, clipStartMs, clipEndMs);

  @override
  String toString() => 'QueueItem(file $fileId, $clipStartMs-$clipEndMs)';
}

/// A position in engine coordinates: which queue item, and how far into it.
///
/// The offset is relative to the item's clip start, which is how clipped sources report position.
/// Use `Timeline.fileOffsetOf` for the absolute offset into the underlying file.
final class QueuePosition {
  const QueuePosition({required this.itemIndex, required this.offsetMs});

  final int itemIndex;
  final int offsetMs;

  @override
  bool operator ==(Object other) =>
      other is QueuePosition &&
      other.itemIndex == itemIndex &&
      other.offsetMs == offsetMs;

  @override
  int get hashCode => Object.hash(itemIndex, offsetMs);

  @override
  String toString() => 'QueuePosition(item $itemIndex @ ${offsetMs}ms)';
}

/// Something the user can navigate to. Covers the book with no gaps and no overlaps.
sealed class NavigationEntry {
  const NavigationEntry({
    required this.title,
    required this.startMs,
    required this.endMs,
  });

  final String title;

  /// Global start, inclusive.
  final int startMs;

  /// Global end, exclusive.
  final int endMs;

  int get durationMs => endMs - startMs;
}

/// A real chapter from the source.
final class ChapterEntry extends NavigationEntry {
  const ChapterEntry({
    required this.chapterId,
    required super.title,
    required super.startMs,
    required super.endMs,
  });

  final int chapterId;

  @override
  bool operator ==(Object other) =>
      other is ChapterEntry &&
      other.chapterId == chapterId &&
      other.title == title &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(chapterId, title, startMs, endMs);

  @override
  String toString() => 'ChapterEntry($chapterId, "$title", $startMs-$endMs)';
}

/// A marker embedded in the file, presented as a virtual chapter.
///
/// §4.5: these exist for navigation and display only. Progress and bookmarks stay anchored to the
/// source chapter, so a marker entry deliberately carries no chapter id of its own.
final class MarkerEntry extends NavigationEntry {
  const MarkerEntry({
    required super.title,
    required super.startMs,
    required super.endMs,
  });

  @override
  bool operator ==(Object other) =>
      other is MarkerEntry &&
      other.title == title &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(title, startMs, endMs);

  @override
  String toString() => 'MarkerEntry("$title", $startMs-$endMs)';
}
