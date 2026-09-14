import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:test/test.dart';

final t0 = DateTime.utc(2026, 9, 1);

ChapterSnapshot chapter({int positionMs = 0, bool listened = false}) =>
    ChapterSnapshot(
      key: 'one',
      title: 'One',
      sourceIndex: 0,
      createdAt: t0,
      updatedAt: t0,
      lastPositionMs: positionMs,
      isListened: listened,
    );

BookSnapshot book({
  List<ChapterSnapshot> chapters = const [],
  ProgressSnapshot? progress,
  List<SessionSnapshot> sessions = const [],
  List<BookmarkSnapshot> bookmarks = const [],
  List<String> categories = const [],
}) => BookSnapshot(
  sourceId: 1,
  key: 'book',
  details: BookDetailsSnapshot(title: 'A Book'),
  createdAt: t0,
  updatedAt: t0,
  chapters: chapters,
  progress: progress,
  sessions: sessions,
  bookmarks: bookmarks,
  categories: categories,
);

BookMerge merge({
  EditedDetails? edits,
  bool addToLibrary = false,
  double? playbackSpeed,
  List<String> newCategories = const [],
}) => BookMerge(
  sourceId: 1,
  key: 'book',
  updatedAt: t0,
  edits: edits,
  addToLibrary: addToLibrary,
  playbackSpeed: playbackSpeed,
  newCategories: newCategories,
);

void main() {
  group('book details', () {
    test('take the named fields from other details and keep the rest', () {
      final here = BookDetailsSnapshot(
        title: 'Here',
        description: 'Here.',
        genres: const ['Fiction'],
      );
      final there = BookDetailsSnapshot(title: 'There', description: 'There.');

      final mixed = here.withFieldsFrom(there, {BookField.title});
      expect(mixed.title, 'There');
      expect(mixed.description, 'Here.');
      expect(mixed.genres, ['Fiction']);
      expect(
        here.title,
        'Here',
        reason: 'the details taken from are unchanged',
      );
    });

    test('are equal when every field is, comparing genres by content', () {
      final a = BookDetailsSnapshot(title: 'A', genres: ['Fiction']);
      final b = BookDetailsSnapshot(title: 'A', genres: ['Fiction']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          BookDetailsSnapshot(title: 'A', genres: ['Fiction'], subtitle: ''),
        ),
      );
    });

    test('cannot be changed through the genres they were given', () {
      final genres = ['Fiction'];
      final details = BookDetailsSnapshot(title: 'A', genres: genres);
      genres.add('Added later');
      expect(details.genres, ['Fiction']);
      expect(() => details.genres.add('Added'), throwsUnsupportedError);
    });
  });

  test('a chapter has progress once started or listened to', () {
    expect(chapter().hasProgress, isFalse);
    expect(chapter(positionMs: 1).hasProgress, isTrue);
    expect(chapter(listened: true).hasProgress, isTrue);
  });

  test('a book carries user data through progress, history, bookmarks, a started chapter or a category', () {
    expect(book(chapters: [chapter()]).carriesUserData, isFalse);
    expect(book(chapters: [chapter(positionMs: 1)]).carriesUserData, isTrue);
    expect(
      book(
        progress: ProgressSnapshot(
          chapterKey: 'one',
          chapterPositionMs: 0,
          globalPositionMs: 0,
          updatedAt: t0,
          deviceId: 'this-pc',
        ),
      ).carriesUserData,
      isTrue,
    );
    expect(
      book(
        sessions: [
          SessionSnapshot(
            startedAt: t0,
            endedAt: t0,
            startGlobalMs: 0,
            endGlobalMs: 0,
            speed: 1,
            deviceId: 'this-pc',
          ),
        ],
      ).carriesUserData,
      isTrue,
    );
    expect(
      book(
        bookmarks: [
          BookmarkSnapshot(chapterKey: 'one', positionMs: 0, createdAt: t0),
        ],
      ).carriesUserData,
      isTrue,
    );
    expect(book(categories: ['Next up']).carriesUserData, isTrue);
  });

  group('a restore plan', () {
    test('with nothing in it changes nothing', () {
      expect(const RestorePlan().isEmpty, isTrue);
      expect(
        const RestorePlan(
          newCategories: [CategorySnapshot(name: 'Next up', sortOrder: 0)],
        ).isEmpty,
        isFalse,
      );
    });

    test("changes a book's own row only through its details, place in the library or speed", () {
      expect(merge().isEmpty, isTrue);

      final joining = merge(newCategories: ['Next up']);
      expect(joining.changesBook, isFalse);
      expect(joining.isEmpty, isFalse);

      expect(merge(addToLibrary: true).changesBook, isTrue);
      expect(merge(playbackSpeed: 1.5).changesBook, isTrue);
      expect(
        merge(
          edits: (
            details: BookDetailsSnapshot(title: 'My Title'),
            userOverrides: const {BookField.title},
          ),
        ).changesBook,
        isTrue,
      );
    });
  });
}
