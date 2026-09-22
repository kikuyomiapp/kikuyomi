// A source's filters. Values are keyed by a filter's key, so a key that repeats or a default that
// is not one of the options would make a search set something other than what it says.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  const options = [
    {'value': 'any', 'label': 'Any'},
    {'value': 'fiction', 'label': 'Fiction'},
  ];

  test('reads every kind the contract has', () {
    final filters = decoder.decodeFilters([
      {'kind': 'header', 'label': 'Catalogue'},
      {'kind': 'separator'},
      {
        'kind': 'text',
        'key': 'author',
        'label': 'Author',
        'default': 'Melville',
      },
      {
        'kind': 'checkbox',
        'key': 'solo',
        'label': 'Solo reading',
        'default': true,
      },
      {
        'kind': 'tristate',
        'key': 'fiction',
        'label': 'Fiction',
        'default': 'exclude',
      },
      {
        'kind': 'select',
        'key': 'genre',
        'label': 'Genre',
        'options': options,
        'default': 'fiction',
      },
      {
        'kind': 'sort',
        'key': 'order',
        'label': 'Order',
        'options': options,
        'default': {'value': 'fiction', 'ascending': false},
      },
      {
        'kind': 'group',
        'label': 'More',
        'filters': [
          {'kind': 'checkbox', 'key': 'abridged', 'label': 'Abridged'},
        ],
      },
    ]);

    expect(filters, [
      const HeaderFilter(label: 'Catalogue'),
      const SeparatorFilter(),
      const TextFilter(key: 'author', label: 'Author', defaultText: 'Melville'),
      const CheckboxFilter(
        key: 'solo',
        label: 'Solo reading',
        defaultChecked: true,
      ),
      const TriStateFilter(
        key: 'fiction',
        label: 'Fiction',
        defaultValue: TriState.exclude,
      ),
      SelectFilter(
        key: 'genre',
        label: 'Genre',
        options: const [
          Option(value: 'any', label: 'Any'),
          Option(value: 'fiction', label: 'Fiction'),
        ],
        defaultOption: 'fiction',
      ),
      SortFilter(
        key: 'order',
        label: 'Order',
        options: const [
          Option(value: 'any', label: 'Any'),
          Option(value: 'fiction', label: 'Fiction'),
        ],
        defaultValue: const SortValue(value: 'fiction', ascending: false),
      ),
      GroupFilter(
        label: 'More',
        filters: const [CheckboxFilter(key: 'abridged', label: 'Abridged')],
      ),
    ]);
  });

  test('gives a filter without a default the one the contract says', () {
    final filters = decoder.decodeFilters([
      {'kind': 'text', 'key': 'author', 'label': 'Author'},
      {'kind': 'checkbox', 'key': 'solo', 'label': 'Solo'},
      {'kind': 'tristate', 'key': 'fiction', 'label': 'Fiction'},
      {'kind': 'select', 'key': 'genre', 'label': 'Genre', 'options': options},
      {'kind': 'sort', 'key': 'order', 'label': 'Order', 'options': options},
    ]);

    expect((filters[0] as TextFilter).defaultText, '');
    expect((filters[1] as CheckboxFilter).defaultChecked, isFalse);
    expect((filters[2] as TriStateFilter).defaultValue, TriState.ignore);
    expect(
      (filters[3] as SelectFilter).defaultOption,
      'any',
      reason: 'the first option',
    );
    expect(
      (filters[4] as SortFilter).defaultValue,
      isNull,
      reason: 'no order chosen: the site lists results in its own',
    );
  });

  test('lists the filters that carry a value, groups included, in order', () {
    final filters = decoder.decodeFilters([
      {'kind': 'header', 'label': 'Catalogue'},
      {'kind': 'text', 'key': 'author', 'label': 'Author'},
      {
        'kind': 'group',
        'label': 'More',
        'filters': [
          {'kind': 'separator'},
          {'kind': 'checkbox', 'key': 'abridged', 'label': 'Abridged'},
        ],
      },
    ]);
    expect(
      [for (final filter in valueFilters(filters)) filter.key],
      ['author', 'abridged'],
    );
  });

  test('refuses two filters sharing a key, wherever they sit', () {
    expect(
      () => decoder.decodeFilters([
        {'kind': 'text', 'key': 'author', 'label': 'Author'},
        {'kind': 'checkbox', 'key': 'author', 'label': 'Author?'},
      ]),
      rejects('filters[1].key', 'repeats the key of filters[0]'),
    );
    expect(
      () => decoder.decodeFilters([
        {'kind': 'text', 'key': 'author', 'label': 'Author'},
        {
          'kind': 'group',
          'label': 'More',
          'filters': [
            {'kind': 'text', 'key': 'author', 'label': 'Author again'},
          ],
        },
      ]),
      rejects('filters[1].filters[0].key', 'repeats the key of filters[0]'),
    );
  });

  test('refuses a group inside a group: groups are one level deep', () {
    expect(
      () => decoder.decodeFilters([
        {
          'kind': 'group',
          'label': 'More',
          'filters': [
            {'kind': 'group', 'label': 'Even more', 'filters': <Object?>[]},
          ],
        },
      ]),
      rejects('filters[0].filters[0]', 'one level deep'),
    );
  });

  test('holds 100 filters, counting groups and what is inside them', () {
    List<Object?> flat(int count) => [
      for (var i = 0; i < count; i++)
        {'kind': 'checkbox', 'key': 'k$i', 'label': 'L$i'},
    ];
    expect(decoder.decodeFilters(flat(100)), hasLength(100));
    expect(
      decoder.decodeFilters([
        {'kind': 'group', 'label': 'More', 'filters': flat(99)},
      ]),
      hasLength(1),
    );
  });

  test('refuses the hundred-and-first filter, inside a group as much as outside one', () {
    List<Object?> flat(int count) => [
      for (var i = 0; i < count; i++)
        {'kind': 'checkbox', 'key': 'k$i', 'label': 'L$i'},
    ];
    expect(
      () => decoder.decodeFilters(flat(101)),
      rejects('filters', 'at most 100'),
    );
    expect(
      () => decoder.decodeFilters([
        {'kind': 'group', 'label': 'More', 'filters': flat(100)},
      ]),
      rejects('filters', 'more than 100 filters'),
    );
  });

  test('refuses a select or sort whose default is not one of its options', () {
    expect(
      () => decoder.decodeFilters([
        {
          'kind': 'select',
          'key': 'genre',
          'label': 'Genre',
          'options': options,
          'default': 'poetry',
        },
      ]),
      rejects('filters[0].default', 'not one of this filter\'s options'),
    );
    expect(
      () => decoder.decodeFilters([
        {
          'kind': 'sort',
          'key': 'order',
          'label': 'Order',
          'options': options,
          'default': {'value': 'poetry', 'ascending': true},
        },
      ]),
      rejects('filters[0].default.value', 'not one of this filter\'s options'),
    );
  });

  test('refuses a sort default with no direction', () {
    expect(
      () => decoder.decodeFilters([
        {
          'kind': 'sort',
          'key': 'order',
          'label': 'Order',
          'options': options,
          'default': {'value': 'any'},
        },
      ]),
      rejects('filters[0].default.ascending', 'missing'),
    );
  });

  test(
    'refuses a select with no options, or with two options sharing a value',
    () {
      expect(
        () => decoder.decodeFilters([
          {
            'kind': 'select',
            'key': 'genre',
            'label': 'Genre',
            'options': <Object?>[],
          },
        ]),
        rejects('filters[0].options', 'needs options'),
      );
      expect(
        () => decoder.decodeFilters([
          {
            'kind': 'select',
            'key': 'genre',
            'label': 'Genre',
            'options': [
              {'value': 'any', 'label': 'Any'},
              {'value': 'any', 'label': 'Anything'},
            ],
          },
        ]),
        rejects(
          'filters[0].options[1].value',
          'repeats the value of filters[0].options[0]',
        ),
      );
    },
  );

  test('refuses a tri-state default that is not one of the three', () {
    expect(
      () => decoder.decodeFilters([
        {
          'kind': 'tristate',
          'key': 'fiction',
          'label': 'Fiction',
          'default': 'maybe',
        },
      ]),
      rejects('filters[0].default', '"maybe" is not'),
    );
  });

  test('refuses a kind this app does not know, so a kind added later is never guessed at', () {
    expect(
      () => decoder.decodeFilters([
        {
          'kind': 'multiselect',
          'key': 'genres',
          'label': 'Genres',
          'options': options,
        },
      ]),
      rejects('filters[0].kind', 'is not a filter kind'),
    );
  });

  test('refuses a filter with no key or no label', () {
    expect(
      () => decoder.decodeFilters([
        {'kind': 'text', 'label': 'Author'},
      ]),
      rejects('filters[0].key', 'missing'),
    );
    expect(
      () => decoder.decodeFilters([
        {'kind': 'text', 'key': 'author'},
      ]),
      rejects('filters[0].label', 'missing'),
    );
    expect(
      () => decoder.decodeFilters([
        {'label': 'Author'},
      ]),
      rejects('filters[0].kind', 'missing'),
    );
  });

  test('refuses anything but an array of filters', () {
    expect(
      () => decoder.decodeFilters(null),
      rejects('filters', 'got nothing'),
    );
    expect(
      () => decoder.decodeFilters('genre'),
      rejects('filters', 'expected an array'),
    );
    expect(
      () => decoder.decodeFilters(['genre']),
      rejects('filters[0]', 'expected an object'),
    );
  });

  test('takes no filters at all', () {
    expect(decoder.decodeFilters(<Object?>[]), isEmpty);
  });
}
