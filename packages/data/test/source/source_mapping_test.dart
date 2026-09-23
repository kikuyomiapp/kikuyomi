import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart' as api;
import 'package:test/test.dart';

void main() {
  group('a source\'s details, as the merge takes them', () {
    test('every field crosses onto its column', () {
      final stored = toStoredDetails(
        api.BookDetails(
          key: '753',
          title: 'Moby Dick',
          subtitle: 'or, The Whale',
          authors: const ['Herman Melville'],
          series: const api.Series(name: 'Sea Tales', index: 2.5),
          description: 'A whale.\nAnd a captain.',
          coverUrl: Uri.parse('https://archive.org/services/img/moby'),
          genres: const ['Nautical & Marine Fiction'],
          language: 'en',
          publisher: 'LibriVox',
          publishedDate: '1851',
          isbn: '9780000000000',
          abridged: false,
          totalDurationMs: 3600000,
          status: api.BookStatus.ongoing,
          contentRating: api.ContentRating.everyone,
          webUrl: Uri.parse('https://librivox.org/moby-dick/'),
        ),
      );

      expect(stored.title, 'Moby Dick');
      expect(stored.subtitle, 'or, The Whale');
      expect(stored.seriesName, 'Sea Tales');
      expect(stored.seriesIndex, 2.5);
      expect(stored.description, 'A whale.\nAnd a captain.');
      expect(stored.coverUrl, 'https://archive.org/services/img/moby');
      expect(stored.genres, ['Nautical & Marine Fiction']);
      expect(stored.language, 'en');
      expect(stored.publisher, 'LibriVox');
      expect(stored.publishedDate, '1851');
      expect(stored.isbn, '9780000000000');
      expect(stored.abridged, isFalse);
      expect(stored.totalDurationMs, 3600000);
      expect(stored.status, 'ongoing');
      expect(stored.contentRating, 'everyone');
      expect(stored.webUrl, 'https://librivox.org/moby-dick/');
    });

    test('a status of unknown is read as "the source did not say"', () {
      // The contract reads an unreadable or missing status as `unknown`, so it cannot mean "this
      // book's state is unknown". Absent, it falls under the merge's rule that a field the source
      // did not give keeps its stored value.
      final stored = toStoredDetails(
        api.BookDetails(key: 'k', title: 'A Book'),
      );

      expect(stored.status, isNull);

      final merge = mergeBookDetails(
        stored: BookDetails(status: 'complete'),
        incoming: stored,
      );
      expect(merge.details.status, 'complete');
      expect(merge.changedFields, isNot(contains(BookField.status)));
    });

    test('no content rating stays no content rating', () {
      final stored = toStoredDetails(
        api.BookDetails(key: 'k', title: 'A Book'),
      );

      expect(stored.contentRating, isNull);
    });
  });

  group('a source\'s chapters, as sync takes them', () {
    test('the list\'s order is the book\'s order', () {
      final incoming = toIncomingChapters([
        api.ChapterInfo(key: 'c', title: 'Third'),
        api.ChapterInfo(key: 'a', title: 'First'),
        api.ChapterInfo(key: 'b', title: 'Second'),
      ]);

      expect(incoming.map((c) => c.key), ['c', 'a', 'b']);
      expect(incoming.map((c) => c.sourceIndex), [0, 1, 2]);
    });

    test('a release time and a group heading cross too', () {
      final published = DateTime.utc(2026, 5, 6);
      final incoming = toIncomingChapters([
        api.ChapterInfo(
          key: 'a',
          title: 'First',
          durationMs: 1000,
          publishedAt: published,
          group: 'Part One',
        ),
      ]);

      expect(incoming.single.durationMs, 1000);
      expect(incoming.single.publishedAt, published);
      expect(incoming.single.group, 'Part One');
    });
  });

  test('credits come from the details, in credit order', () {
    final credits = toCredits(
      api.BookDetails(
        key: 'k',
        title: 'A Book',
        authors: const ['Herman Melville'],
        narrators: const ['Stewart Wills', 'Ruth Golding'],
      ),
    );

    expect(credits.of(ContributorRole.author).map((c) => c.name), [
      'Herman Melville',
    ]);
    expect(credits.of(ContributorRole.narrator).map((c) => c.name), [
      'Stewart Wills',
      'Ruth Golding',
    ]);
  });
}
