import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:test/test.dart';

BookDetails storedBook() => BookDetails(
  title: 'The Stored Title',
  description: 'A description the user rewrote.',
  coverUrl: 'https://example.org/old-cover.jpg',
  seriesName: 'A Series',
  seriesIndex: 2,
  genres: const ['Fiction', 'Mystery'],
  language: 'en',
  abridged: true,
  totalDurationMs: 36000000,
);

void main() {
  group('source-provided fields', () {
    test('overwrite stored values when nothing protects them', () {
      final result = mergeBookDetails(
        stored: storedBook(),
        incoming: BookDetails(
          title: 'A New Title',
          seriesIndex: 2.5,
          totalDurationMs: 36012000,
        ),
      );
      expect(result.details.title, 'A New Title');
      expect(result.details.seriesIndex, 2.5);
      expect(result.details.totalDurationMs, 36012000);
      expect(result.changedFields, {
        BookField.title,
        BookField.seriesIndex,
        BookField.totalDurationMs,
      });
    });

    test(
      'an identical refresh changes nothing, so the write can be skipped',
      () {
        final result = mergeBookDetails(
          stored: storedBook(),
          incoming: storedBook(),
        );
        expect(result.changedFields, isEmpty);
        expect(result.coverChanged, isFalse);
      },
    );

    test('a list with the same contents is not a change', () {
      final result = mergeBookDetails(
        stored: storedBook(),
        incoming: BookDetails(genres: ['Fiction', 'Mystery']),
      );
      expect(result.changedFields, isNot(contains(BookField.genres)));
    });

    test('a present but falsy value is real and overwrites', () {
      final result = mergeBookDetails(
        stored: storedBook(),
        incoming: BookDetails(abridged: false),
      );
      expect(result.details.abridged, isFalse);
      expect(result.changedFields, {BookField.abridged});
    });
  });

  group('user overrides (§4.4)', () {
    test('a field the user edited keeps their value', () {
      final result = mergeBookDetails(
        stored: storedBook(),
        incoming: BookDetails(
          title: 'The Source Title',
          description: 'The source description.',
          language: 'fr',
        ),
        userOverrides: {BookField.title, BookField.description},
      );
      expect(result.details.title, 'The Stored Title');
      expect(result.details.description, 'A description the user rewrote.');
      expect(result.details.language, 'fr');
      expect(result.changedFields, {BookField.language});
    });
  });

  group('covers (§4.4)', () {
    test('a custom cover survives a new cover from the source', () {
      final result = mergeBookDetails(
        stored: storedBook(),
        incoming: BookDetails(coverUrl: 'https://example.org/new-cover.jpg'),
        hasCustomCover: true,
      );
      expect(result.details.coverUrl, 'https://example.org/old-cover.jpg');
      expect(result.coverChanged, isFalse);
    });

    test(
      'without a custom cover, a new cover is taken and flagged for refetching',
      () {
        final result = mergeBookDetails(
          stored: storedBook(),
          incoming: BookDetails(coverUrl: 'https://example.org/new-cover.jpg'),
        );
        expect(result.details.coverUrl, 'https://example.org/new-cover.jpg');
        expect(result.coverChanged, isTrue);
      },
    );
  });

  group('fields the source did not provide', () {
    test('do not erase what is stored', () {
      final result = mergeBookDetails(
        stored: storedBook(),
        incoming: BookDetails(title: '   ', description: '', genres: const []),
      );
      expect(result.details.title, 'The Stored Title');
      expect(result.details.description, 'A description the user rewrote.');
      expect(result.details.genres, ['Fiction', 'Mystery']);
      expect(result.details.seriesName, 'A Series');
      expect(result.changedFields, isEmpty);
    });
  });

  test('merged details cannot be mutated afterwards', () {
    final result = mergeBookDetails(
      stored: storedBook(),
      incoming: BookDetails(genres: ['Horror']),
    );
    expect(() => result.details.genres.add('Romance'), throwsUnsupportedError);
    expect(
      () => result.changedFields.add(BookField.title),
      throwsUnsupportedError,
    );
  });
}
