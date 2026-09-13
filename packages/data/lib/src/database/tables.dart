/// Schema version 1, following docs/architecture.md §4.3.
///
/// Version 1 holds what Phase 1 needs: sources, books and their contributors, chapters, the physical
/// file layout, progress, listening history, bookmarks and categories. Tables that belong to later
/// phases arrive in later schema versions, each with its own migration: `repository`, `extension`
/// and `extension_preference` in Phase 2, `download_task` in Phase 3, and `smart_collection` and
/// the `book_fts` full-text index in Phase 4.
///
/// Row classes are named `…Row`. §4.1 keeps database records, domain entities and extension DTOs as
/// three separate types, and the suffix keeps a record from being mistaken for an entity.
library;

import 'package:drift/drift.dart';

import 'converters.dart';

/// A content source: a built-in one such as Local files, or one provided by an extension.
@DataClassName('SourceRow')
class Sources extends Table {
  /// The stable 64-bit hash §3 describes, not an autoincrement.
  IntColumn get id => integer()();

  /// Null for a built-in source. Becomes a foreign key when the extension table arrives.
  TextColumn get extensionId => text().nullable()();
  TextColumn get key => text()();
  TextColumn get name => text()();
  TextColumn get lang => text()();
  TextColumn get contentRating => text().nullable()();
  BoolColumn get isEnabled => boolean().withDefault(const Constant(true))();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastUsedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('BookRow')
@TableIndex(name: 'books_library', columns: {#inLibrary, #dateAdded})
class Books extends Table {
  /// Surrogate key, used only for joins. §4.4: a book's identity is its source and key.
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sourceId => integer().references(Sources, #id)();
  TextColumn get key => text()();
  TextColumn get title => text()();
  TextColumn get subtitle => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get coverUrl => text().nullable()();
  TextColumn get coverLocalPath => text().nullable()();
  DateTimeColumn get coverUpdatedAt => dateTime().nullable()();
  TextColumn get seriesName => text().nullable()();
  RealColumn get seriesIndex => real().nullable()();
  TextColumn get genres => text()
      .withDefault(const Constant('[]'))
      .map(const StringListConverter())();
  TextColumn get language => text().nullable()();
  TextColumn get publisher => text().nullable()();
  TextColumn get publishedDate => text().nullable()();
  TextColumn get isbn => text().nullable()();
  BoolColumn get abridged => boolean().nullable()();
  TextColumn get status => text().nullable()();
  TextColumn get contentRating => text().nullable()();
  IntColumn get totalDurationMs => integer().nullable()();
  TextColumn get webUrl => text().nullable()();
  BoolColumn get inLibrary => boolean().withDefault(const Constant(false))();
  DateTimeColumn get dateAdded => dateTime().nullable()();
  DateTimeColumn get lastRefreshedAt => dateTime().nullable()();
  BoolColumn get detailsFetched =>
      boolean().withDefault(const Constant(false))();
  TextColumn get userOverrides => text()
      .withDefault(const Constant('[]'))
      .map(const BookFieldSetConverter())();

  /// §4.3: playback speed is remembered per book.
  RealColumn get playbackSpeed => real().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {sourceId, key},
  ];
}

/// An author or narrator. §4.3 normalises contributors because narrators matter in audiobooks:
/// users filter by them, follow them, and use them to tell editions apart.
@DataClassName('PersonRow')
class People extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Unique, so the same narrator across books is one person to filter by. Two different people
  /// sharing a name will merge; that is the accepted cost of not having an identity from sources.
  TextColumn get name => text().unique()();
}

enum ContributorRole { author, narrator }

@DataClassName('BookPersonRow')
class BookPeople extends Table {
  IntColumn get bookId =>
      integer().references(Books, #id, onDelete: KeyAction.cascade)();
  IntColumn get personId => integer().references(People, #id)();
  TextColumn get role => textEnum<ContributorRole>()();

  /// Credit order within the role.
  IntColumn get ordinal => integer()();

  @override
  Set<Column<Object>> get primaryKey => {bookId, personId, role};
}

@DataClassName('ChapterRow')
@TableIndex(name: 'chapters_order', columns: {#bookId, #sourceIndex})
class Chapters extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId =>
      integer().references(Books, #id, onDelete: KeyAction.cascade)();
  TextColumn get key => text()();
  TextColumn get title => text()();
  IntColumn get sourceIndex => integer()();
  TextColumn get groupName => text().nullable()();
  IntColumn get durationMs => integer().nullable()();
  DateTimeColumn get publishedAt => dateTime().nullable()();
  BoolColumn get isListened => boolean().withDefault(const Constant(false))();
  DateTimeColumn get listenedAt => dateTime().nullable()();

  /// Chapter-relative, per §4.5.
  IntColumn get lastPositionMs => integer().withDefault(const Constant(0))();

  /// §4.4: chapters a source stops reporting are soft-deleted, never removed outright while they
  /// carry progress, bookmarks or downloads.
  BoolColumn get removedFromSource =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {bookId, key},
  ];
}

/// One physical audio file known for a book.
@DataClassName('MediaFileRow')
class MediaFiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId =>
      integer().references(Books, #id, onDelete: KeyAction.cascade)();
  TextColumn get fileKey => text()();
  TextColumn get format => text().nullable()();
  IntColumn get durationMs => integer().nullable()();

  /// Not in §4.3's column list, but §4.5 requires it: durations are estimated until a file is
  /// probed, and the Timeline has to know which figures are which.
  BoolColumn get durationIsEstimate =>
      boolean().withDefault(const Constant(true))();
  IntColumn get sizeBytes => integer().nullable()();
  TextColumn get embeddedMarkers =>
      text().map(const MarkerListConverter()).nullable()();

  /// Non-null once the file has been downloaded.
  TextColumn get localPath => text().nullable()();
  DateTimeColumn get downloadedAt => dateTime().nullable()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {bookId, fileKey},
  ];
}

/// The persisted layout of each chapter across physical files. No URLs are stored: §4.3 treats them
/// as ephemeral, and the Timeline never needs one.
@DataClassName('ChapterSegmentRow')
class ChapterSegments extends Table {
  IntColumn get chapterId =>
      integer().references(Chapters, #id, onDelete: KeyAction.cascade)();
  IntColumn get ordinal => integer()();

  /// Deliberately not cascading: a file cannot be deleted out from under a chapter's layout.
  IntColumn get mediaFileId => integer().references(MediaFiles, #id)();
  IntColumn get startMs => integer().withDefault(const Constant(0))();

  /// Null means to the end of the file, as in the Timeline's own segments, so a whole-file segment
  /// follows its file's duration when a probe refines it and nothing has to be rewritten.
  IntColumn get endMs => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {chapterId, ordinal};
}

/// One row per started book: the source of truth for Continue Listening.
@DataClassName('PlaybackStateRow')
@TableIndex(name: 'playback_states_recent', columns: {#updatedAt})
class PlaybackStates extends Table {
  IntColumn get bookId =>
      integer().references(Books, #id, onDelete: KeyAction.cascade)();

  /// Not cascading: the database itself refuses to delete a chapter that holds a book's progress.
  IntColumn get chapterId => integer().references(Chapters, #id)();
  IntColumn get chapterPositionMs => integer()();

  /// Derived from the Timeline and cached for sorting and display. [chapterPositionMs] is the truth.
  IntColumn get globalPositionMs => integer()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get deviceId => text()();

  @override
  Set<Column<Object>> get primaryKey => {bookId};
}

@DataClassName('ListeningSessionRow')
@TableIndex(name: 'listening_sessions_started', columns: {#startedAt})
class ListeningSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId =>
      integer().references(Books, #id, onDelete: KeyAction.cascade)();

  /// Nullable and cleared when the chapter is purged. Listening history should outlive a chapter the
  /// source dropped; §4.4's "keep while it carries user data" rule covers progress, bookmarks and
  /// downloads, not history.
  IntColumn get chapterId => integer().nullable().references(
    Chapters,
    #id,
    onDelete: KeyAction.setNull,
  )();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime()();
  IntColumn get startGlobalMs => integer()();
  IntColumn get endGlobalMs => integer()();
  RealColumn get speed => real()();
  TextColumn get deviceId => text()();
}

@DataClassName('BookmarkRow')
class Bookmarks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId =>
      integer().references(Books, #id, onDelete: KeyAction.cascade)();

  /// Not cascading, for the same reason as progress.
  IntColumn get chapterId => integer().references(Chapters, #id)();
  IntColumn get positionMs => integer()();
  TextColumn get title => text().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
}

/// A manual, many-to-many library tab, per ADR-0009.
@DataClassName('CategoryRow')
class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer()();

  /// Per-category sort, filter and display settings, packed as §4.3 describes.
  IntColumn get flags => integer().withDefault(const Constant(0))();
}

@DataClassName('BookCategoryRow')
class BookCategories extends Table {
  IntColumn get bookId =>
      integer().references(Books, #id, onDelete: KeyAction.cascade)();
  IntColumn get categoryId =>
      integer().references(Categories, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column<Object>> get primaryKey => {bookId, categoryId};
}
