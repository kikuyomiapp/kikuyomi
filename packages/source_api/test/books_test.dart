// Reading a page of results and a book's details. Every field of these ends up in the library
// (§4.4), so what a broken source can put there is what these pin down.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('a page of results', () {
    test('reads the items and whether there is another page', () {
      final result = decoder.decodeBookPage(
        page([
          {
            'key': 'b1',
            'title': 'Moby-Dick',
            'coverUrl': 'https://img.cdn.example.org/1.jpg',
            'authors': ['Herman Melville'],
            'narrators': ['Stewart Wills'],
            'durationMs': 87000000,
          },
          summary(key: 'b2', title: 'Walden'),
        ], hasNextPage: true),
      );

      expect(result.hasNextPage, isTrue);
      expect(result.items, [
        BookSummary(
          key: 'b1',
          title: 'Moby-Dick',
          coverUrl: Uri.parse('https://img.cdn.example.org/1.jpg'),
          authors: ['Herman Melville'],
          narrators: ['Stewart Wills'],
          durationMs: 87000000,
        ),
        BookSummary(key: 'b2', title: 'Walden'),
      ]);
    });

    test('leaves authors and narrators empty when the source gives none', () {
      final item = decoder.decodeBookPage(page([summary()])).items.single;
      expect(item.authors, isEmpty);
      expect(item.narrators, isEmpty);
      expect(item.coverUrl, isNull);
      expect(item.durationMs, isNull);
    });

    test('is empty without being the end of the list', () {
      final result = decoder.decodeBookPage(page([], hasNextPage: true));
      expect(result.items, isEmpty);
      expect(result.hasNextPage, isTrue);
    });

    test('keeps a book that repeats within the page only once', () {
      final result = decoder.decodeBookPage(
        page([
          summary(title: 'Moby-Dick'),
          summary(key: 'b2', title: 'Walden'),
          summary(title: 'Moby-Dick, featured'),
        ]),
      );
      expect([for (final item in result.items) item.key], ['b1', 'b2']);
      expect(result.items.first.title, 'Moby-Dick');
    });

    test('holds 200 results, and refuses 201', () {
      List<Object?> items(int count) => [
        for (var i = 0; i < count; i++) summary(key: 'b$i'),
      ];
      expect(decoder.decodeBookPage(page(items(200))).items, hasLength(200));
      expect(
        () => decoder.decodeBookPage(page(items(201))),
        rejects('items', 'at most 200'),
      );
    });

    test('needs items and hasNextPage', () {
      expect(
        () => decoder.decodeBookPage({'hasNextPage': false}),
        rejects('items', 'missing'),
      );
      expect(
        () => decoder.decodeBookPage({'items': <Object?>[]}),
        rejects('hasNextPage', 'missing'),
      );
      expect(
        () =>
            decoder.decodeBookPage({'items': <Object?>[], 'hasNextPage': 'no'}),
        rejects('hasNextPage', 'expected true or false'),
      );
    });

    test('names the item that is wrong, and its field', () {
      expect(
        () => decoder.decodeBookPage(
          page([summary(), summary(key: 'b2'), 'Walden']),
        ),
        rejects('items[2]', 'expected an object, got a string'),
      );
      expect(
        () => decoder.decodeBookPage(
          page([summary(), summary(key: 'b2'), summary(key: 'b3', title: 7)]),
        ),
        rejects('items[2].title', 'expected a string, got a number'),
      );
      expect(
        () => decoder.decodeBookPage(page([summary(title: text(1001))])),
        rejects('items[0].title', 'longer than 1,000 characters'),
      );
    });

    test('is not a page at all when it is an array or nothing', () {
      expect(
        () => decoder.decodeBookPage([]),
        rejects('the result', 'expected an object'),
      );
      expect(
        () => decoder.decodeBookPage(null),
        rejects('the result', 'got nothing'),
      );
    });
  });

  group('a book\'s details', () {
    test('read every field the contract has', () {
      final book = decoder.decodeBookDetails(
        details(
          and: {
            'subtitle': 'or, The Whale',
            'series': {'name': 'Whales', 'index': 2.5},
            'description': 'Call me Ishmael.\nSome years ago…',
            'coverUrl': 'https://example.org/1.jpg',
            'genres': ['Fiction', 'Adventure'],
            'language': 'en',
            'publisher': 'Harper & Brothers',
            'publishedDate': '1851-10-18',
            'isbn': '9780000000000',
            'abridged': false,
            'totalDurationMs': 87000000,
            'status': 'ongoing',
            'contentRating': 'mature',
            'webUrl': 'https://example.org/books/1',
          },
        ),
      );

      expect(book.key, 'b1');
      expect(book.title, 'Moby-Dick');
      expect(book.subtitle, 'or, The Whale');
      expect(book.authors, ['Herman Melville']);
      expect(book.narrators, ['Stewart Wills']);
      expect(book.series, const Series(name: 'Whales', index: 2.5));
      expect(book.description, 'Call me Ishmael.\nSome years ago…');
      expect(book.coverUrl, Uri.parse('https://example.org/1.jpg'));
      expect(book.genres, ['Fiction', 'Adventure']);
      expect(book.language, 'en');
      expect(book.publisher, 'Harper & Brothers');
      expect(book.publishedDate, '1851-10-18');
      expect(book.isbn, '9780000000000');
      expect(book.abridged, isFalse);
      expect(book.totalDurationMs, 87000000);
      expect(book.status, BookStatus.ongoing);
      expect(book.contentRating, ContentRating.mature);
      expect(book.webUrl, Uri.parse('https://example.org/books/1'));
    });

    test('leave what the source did not say absent', () {
      final book = decoder.decodeBookDetails(details());
      expect(book.subtitle, isNull);
      expect(book.series, isNull);
      expect(book.description, isNull);
      expect(book.coverUrl, isNull);
      expect(book.language, isNull);
      expect(book.abridged, isNull);
      expect(book.totalDurationMs, isNull);
      expect(
        book.contentRating,
        isNull,
        reason: 'not saying is not "everyone"',
      );
      expect(book.webUrl, isNull);
    });

    test('treat a null field as one the source did not say', () {
      // `undefined` reaches Dart as null, and authors write null for "nothing" as readily.
      final book = decoder.decodeBookDetails(
        details(and: {'subtitle': null, 'series': null, 'contentRating': null}),
      );
      expect(book.subtitle, isNull);
      expect(book.series, isNull);
      expect(book.contentRating, isNull);
    });

    test('need the fields the contract requires', () {
      for (final field in [
        'key',
        'title',
        'authors',
        'narrators',
        'genres',
        'status',
      ]) {
        final without = {...details()}..remove(field);
        expect(
          () => decoder.decodeBookDetails(without),
          rejects(field, 'missing'),
          reason: field,
        );
      }
    });

    test('take an empty list of authors, narrators or genres', () {
      final book = decoder.decodeBookDetails(
        details(
          and: {
            'authors': <Object?>[],
            'narrators': <Object?>[],
            'genres': <Object?>[],
          },
        ),
      );
      expect(book.authors, isEmpty);
      expect(book.genres, isEmpty);
    });

    test('leave an empty name out of a list rather than failing the call', () {
      final book = decoder.decodeBookDetails(
        details(
          and: {
            'authors': ['Herman Melville', '  ', ''],
          },
        ),
      );
      expect(book.authors, ['Herman Melville']);
    });

    test('read a status this app does not know as unknown', () {
      for (final status in ['hiatus', 'COMPLETE', '']) {
        expect(
          decoder.decodeBookDetails(details(and: {'status': status})).status,
          BookStatus.unknown,
          reason: status,
        );
      }
    });

    test('read a content rating this app does not know as the most restrictive there is', () {
      for (final rating in ['adult', 'explicit', 'adults-only', 'EVERYONE']) {
        expect(
          decoder
              .decodeBookDetails(details(and: {'contentRating': rating}))
              .contentRating,
          ContentRating.adult,
          reason: rating,
        );
      }
    });

    test(
      'refuse a series without a name, and a series index that is not a number',
      () {
        expect(
          () => decoder.decodeBookDetails(
            details(
              and: {
                'series': {'index': 1},
              },
            ),
          ),
          rejects('series.name', 'missing'),
        );
        expect(
          () => decoder.decodeBookDetails(
            details(
              and: {
                'series': {'name': 'Whales', 'index': 'two'},
              },
            ),
          ),
          rejects('series.index', 'expected a number'),
        );
        expect(
          () => decoder.decodeBookDetails(
            details(
              and: {
                'series': {'name': 'Whales', 'index': -1},
              },
            ),
          ),
          rejects('series.index', 'less than'),
        );
        expect(
          () => decoder.decodeBookDetails(details(and: {'series': 'Whales'})),
          rejects('series', 'expected an object'),
        );
      },
    );

    test('keep a fractional series index, which is what a novella between two books has', () {
      expect(
        decoder
            .decodeBookDetails(
              details(
                and: {
                  'series': {'name': 'Whales', 'index': 2.5},
                },
              ),
            )
            .series
            ?.index,
        2.5,
      );
      expect(
        decoder
            .decodeBookDetails(
              details(
                and: {
                  'series': {'name': 'Whales', 'index': 3},
                },
              ),
            )
            .series
            ?.index,
        3.0,
      );
    });

    test(
      'refuse a language that is a language\'s name rather than its tag',
      () {
        expect(
          () =>
              decoder.decodeBookDetails(details(and: {'language': 'English'})),
          rejects('language', 'BCP 47'),
        );
        for (final tag in ['en', 'pt-BR', 'zh-Hant-TW', 'en-US']) {
          expect(
            decoder.decodeBookDetails(details(and: {'language': tag})).language,
            tag,
            reason: tag,
          );
        }
      },
    );

    test('hold 200 authors, narrators or genres, and refuse 201', () {
      List<Object?> names(int count) => [
        for (var i = 0; i < count; i++) 'Name $i',
      ];
      expect(
        decoder
            .decodeBookDetails(details(and: {'authors': names(200)}))
            .authors,
        hasLength(200),
      );
      for (final field in ['authors', 'narrators', 'genres']) {
        expect(
          () => decoder.decodeBookDetails(details(and: {field: names(201)})),
          rejects(field, 'at most 200'),
          reason: field,
        );
      }
      expect(
        () => decoder.decodeBookPage(
          page([
            {...summary(), 'narrators': names(201)},
          ]),
        ),
        rejects('items[0].narrators', 'at most 200'),
      );
    });

    test('hold a description of 20,000 characters, and refuse 20,001', () {
      expect(
        decoder
            .decodeBookDetails(details(and: {'description': text(20000)}))
            .description,
        hasLength(20000),
      );
      expect(
        () => decoder.decodeBookDetails(
          details(and: {'description': text(20001)}),
        ),
        rejects('description', 'longer than 20,000 characters'),
      );
    });

    test(
      'refuse a cover or a web page on a host the extension did not declare',
      () {
        expect(
          () => decoder.decodeBookDetails(
            details(and: {'coverUrl': 'https://cdn.evil.com/1.jpg'}),
          ),
          rejects('coverUrl', 'not among the extension\'s domains'),
        );
        expect(
          () => decoder.decodeBookDetails(
            details(and: {'webUrl': 'https://evil.com/books/1'}),
          ),
          rejects('webUrl', 'not among the extension\'s domains'),
        );
        expect(
          () => decoder.decodeBookDetails(
            details(and: {'coverUrl': '/covers/1.jpg'}),
          ),
          rejects('coverUrl', 'absolute'),
        );
      },
    );

    test('ignore a field the contract does not have, so a later version still reads', () {
      final book = decoder.decodeBookDetails(
        details(
          and: {
            'seriesPosition': 3,
            'tags': ['a'],
            'reviews': {'count': 7},
          },
        ),
      );
      expect(book.title, 'Moby-Dick');
    });
  });
}
