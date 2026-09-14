/// What a restore will change, worked out before anything is changed.
///
/// Like chapter synchronisation in the data package, planning is pure: the planner compares a backup
/// with the library and returns a plan, and a `RestoreWriter` applies it. Every merge rule can then be
/// tested without a database, and a restore that would change nothing is recognisable as such.
///
/// A plan has no way to express a deletion, on purpose. A restore only adds to the library and brings
/// back progress. It never removes a book, chapter, category, bookmark or listening session, whatever
/// the backup lacks.
library;

import 'snapshot.dart';

/// Everything a restore changes.
final class RestorePlan {
  const RestorePlan({
    this.newSources = const [],
    this.newCategories = const [],
    this.newBooks = const [],
    this.mergedBooks = const [],
  });

  /// Sources the library does not have.
  final List<SourceSnapshot> newSources;

  /// Categories whose names the library does not have, with sort orders already chosen.
  final List<CategorySnapshot> newCategories;

  /// Books the library does not have, to restore whole, exactly as backed up.
  final List<BookSnapshot> newBooks;

  /// Books the library has, with what the backup adds to them. Only books that change are listed.
  final List<BookMerge> mergedBooks;

  /// True when the restore changes nothing, as when the same backup is restored a second time.
  bool get isEmpty =>
      newSources.isEmpty &&
      newCategories.isEmpty &&
      newBooks.isEmpty &&
      mergedBooks.isEmpty;
}

/// A book's details, with the set of fields in them that the user has edited.
typedef EditedDetails = ({
  BookDetailsSnapshot details,
  Set<BookDetailField> userOverrides,
});

/// What a restore changes in a book the library already has.
///
/// References are by key, as in a snapshot: chapters and files by key within this book, categories
/// by name. Each refers to something the library holds or the same plan adds.
final class BookMerge {
  const BookMerge({
    required this.sourceId,
    required this.key,
    required this.updatedAt,
    this.edits,
    this.addToLibrary = false,
    this.dateAdded,
    this.playbackSpeed,
    this.newFiles = const [],
    this.newChapters = const [],
    this.chapterProgress = const [],
    this.progress,
    this.newSessions = const [],
    this.newBookmarks = const [],
    this.newCategories = const [],
  });

  /// With [key], which book this is: its identity (§4.4).
  final int sourceId;
  final String key;

  /// New details and edited fields for the book, or null to leave both as they are.
  final EditedDetails? edits;

  /// Whether to put the book back in the library, dated [dateAdded].
  final bool addToLibrary;
  final DateTime? dateAdded;

  /// A speed for a book with none remembered, or null to leave the book's speed alone.
  final double? playbackSpeed;

  /// The book's new `updatedAt`, for when [changesBook] is true.
  final DateTime updatedAt;

  /// Files that [newChapters] need and the library lacks.
  final List<MediaFileSnapshot> newFiles;

  /// Chapters the library lacks that carry the user's progress, position or bookmarks, already
  /// marked removed from source.
  final List<ChapterSnapshot> newChapters;

  /// New listened states and positions for chapters the library has.
  final List<ChapterProgress> chapterProgress;

  /// Where the book is up to, replacing what the library has, or null to leave it.
  final ProgressSnapshot? progress;

  final List<SessionSnapshot> newSessions;
  final List<BookmarkSnapshot> newBookmarks;

  /// The names of categories to add the book to.
  final List<String> newCategories;

  /// Whether the book's own row changes, rather than only what hangs off it.
  bool get changesBook =>
      edits != null || addToLibrary || playbackSpeed != null;

  /// True when nothing about the book changes.
  bool get isEmpty =>
      !changesBook &&
      newFiles.isEmpty &&
      newChapters.isEmpty &&
      chapterProgress.isEmpty &&
      progress == null &&
      newSessions.isEmpty &&
      newBookmarks.isEmpty &&
      newCategories.isEmpty;
}

/// A chapter's listened state and position, as a restore sets them.
final class ChapterProgress {
  const ChapterProgress({
    required this.chapterKey,
    required this.isListened,
    required this.listenedAt,
    required this.lastPositionMs,
    required this.updatedAt,
  });

  final String chapterKey;
  final bool isListened;
  final DateTime? listenedAt;
  final int lastPositionMs;

  /// When the progress was recorded in the backup. Written with it, so that restoring the same backup
  /// again finds nothing newer to take.
  final DateTime updatedAt;
}
