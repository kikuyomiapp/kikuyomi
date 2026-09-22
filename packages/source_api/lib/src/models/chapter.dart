/// Chapters as a source lists them: SourceAPI 1.0's `ChapterInfo` and `ChapterRef`.
library;

/// One chapter of a book, as `getChapters` lists it.
///
/// A list of chapters is in listening order: the list's order is the book's order, which is why
/// there is no index field.
final class ChapterInfo {
  const ChapterInfo({
    required this.key,
    required this.title,
    this.durationMs,
    this.publishedAt,
    this.group,
  });

  /// Unique within its book and stable across extension updates: with the book, the chapter's
  /// identity (§4.4).
  final String key;
  final String title;

  /// The chapter's length, in milliseconds, when known. Until a chapter is first resolved, the app
  /// treats it as one file of this length, marked as an estimate.
  final int? durationMs;

  /// When the chapter was released, for serials that release chapters over time. In UTC.
  final DateTime? publishedAt;

  /// A part or volume heading, such as "Part One".
  final String? group;

  @override
  bool operator ==(Object other) =>
      other is ChapterInfo &&
      other.key == key &&
      other.title == title &&
      other.durationMs == durationMs &&
      other.publishedAt == publishedAt &&
      other.group == group;

  @override
  int get hashCode => Object.hash(key, title, durationMs, publishedAt, group);

  @override
  String toString() => 'ChapterInfo($key, "$title")';
}

/// Which chapter of which book: what `resolveMedia` is asked about.
///
/// Both keys, because a chapter key is unique only within its book (§4.4).
final class ChapterRef {
  const ChapterRef({required this.bookKey, required this.chapterKey});

  final String bookKey;
  final String chapterKey;

  @override
  bool operator ==(Object other) =>
      other is ChapterRef &&
      other.bookKey == bookKey &&
      other.chapterKey == chapterKey;

  @override
  int get hashCode => Object.hash(bookKey, chapterKey);

  @override
  String toString() => 'ChapterRef($bookKey, $chapterKey)';
}
