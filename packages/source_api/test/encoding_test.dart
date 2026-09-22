// What the host passes into an extension, and what a saved search survives.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

void main() {
  final filters = <Filter>[
    const HeaderFilter(label: 'Catalogue'),
    const TextFilter(key: 'author', label: 'Author'),
    const CheckboxFilter(key: 'solo', label: 'Solo reading'),
    const TriStateFilter(key: 'fiction', label: 'Fiction'),
    SelectFilter(
      key: 'genre',
      label: 'Genre',
      options: const [
        Option(value: 'any', label: 'Any'),
        Option(value: 'fiction', label: 'Fiction'),
      ],
    ),
    GroupFilter(
      label: 'More',
      filters: [
        SortFilter(
          key: 'order',
          label: 'Order',
          options: const [
            Option(value: 'added', label: 'Date added'),
            Option(value: 'title', label: 'Title'),
          ],
        ),
      ],
    ),
  ];

  final query = SearchQuery(
    text: 'whales',
    filters: FilterValues({
      'author': const TextValue('Melville'),
      'solo': const CheckboxValue(true),
      'fiction': TriState.include,
      'genre': const SelectValue('fiction'),
      'order': const SortValue(value: 'title', ascending: false),
    }),
  );

  group('a search', () {
    test('crosses as plain data, keyed by each filter\'s key', () {
      expect(encodeSearchQuery(query), {
        'text': 'whales',
        'filters': {
          'author': 'Melville',
          'solo': true,
          'fiction': 'include',
          'genre': 'fiction',
          'order': {'value': 'title', 'ascending': false},
        },
      });
    });

    test('carries no filters when nothing was changed from its default', () {
      expect(encodeSearchQuery(const SearchQuery(text: 'whales')), {
        'text': 'whales',
        'filters': <String, Object?>{},
      });
    });

    test('comes back the same when it is read against the same filters', () {
      expect(
        decodeSearchQuery(encodeSearchQuery(query), filters: filters),
        query,
      );
    });

    test('drops a value whose filter the extension no longer declares', () {
      final saved = encodeSearchQuery(query);
      final fewer = [
        for (final filter in filters)
          if (filter != filters[1]) filter,
      ];
      final read = decodeSearchQuery(saved, filters: fewer);
      expect(read.filters['author'], isNull);
      expect(read.filters['genre'], const SelectValue('fiction'));
    });

    test('drops a value whose filter now takes something else', () {
      final changed = <Filter>[
        const CheckboxFilter(key: 'author', label: 'Author known'),
        ...filters.skip(2),
      ];
      expect(
        decodeSearchQuery(
          encodeSearchQuery(query),
          filters: changed,
        ).filters['author'],
        isNull,
      );
    });

    test(
      'drops a select or sort value that is no longer one of the options',
      () {
        final changed = <Filter>[
          ...filters.take(4),
          SelectFilter(
            key: 'genre',
            label: 'Genre',
            options: const [Option(value: 'any', label: 'Any')],
          ),
        ];
        expect(
          decodeSearchQuery(
            encodeSearchQuery(query),
            filters: changed,
          ).filters['genre'],
          isNull,
        );
      },
    );

    test('drops a value that is now the filter\'s own default', () {
      final changed = <Filter>[
        const TextFilter(
          key: 'author',
          label: 'Author',
          defaultText: 'Melville',
        ),
      ];
      final read = decodeSearchQuery(
        encodeSearchQuery(query),
        filters: changed,
      );
      expect(read.filters.isEmpty, isTrue);
      expect(read.text, 'whales');
    });

    test('reads a search with nothing in it', () {
      expect(
        decodeSearchQuery(<String, Object?>{}, filters: filters),
        const SearchQuery(),
      );
    });

    test('refuses a stored value that is not a search at all', () {
      expect(
        () => decodeSearchQuery(null, filters: filters),
        throwsFormatException,
      );
      expect(
        () => decodeSearchQuery('whales', filters: filters),
        throwsFormatException,
      );
      expect(
        () => decodeSearchQuery({'text': 7}, filters: filters),
        throwsFormatException,
      );
      expect(
        () => decodeSearchQuery({'filters': 'author'}, filters: filters),
        throwsFormatException,
      );
    });
  });

  test('a chapter to resolve crosses with both its keys', () {
    expect(
      encodeChapterRef(const ChapterRef(bookKey: 'b1', chapterKey: 'c1')),
      {'bookKey': 'b1', 'chapterKey': 'c1'},
    );
  });

  test(
    'the context to resolve it in crosses as the names the contract uses',
    () {
      expect(
        encodeResolveContext(
          const ResolveContext(
            purpose: ResolvePurpose.download,
            network: NetworkType.cellular,
          ),
        ),
        {'purpose': 'download', 'network': 'cellular'},
      );
      expect(
        encodeResolveContext(
          const ResolveContext(
            purpose: ResolvePurpose.stream,
            network: NetworkType.unknown,
          ),
        ),
        {'purpose': 'stream', 'network': 'unknown'},
      );
    },
  );

  test('a page number crosses as a number, counted from 1', () {
    expect(encodePage(1), 1);
    expect(encodePage(12), 12);
    expect(() => encodePage(0), throwsArgumentError);
    expect(() => encodePage(-1), throwsArgumentError);
  });
}
