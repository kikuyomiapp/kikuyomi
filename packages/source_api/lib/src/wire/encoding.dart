/// Writing what the host passes into an extension as plain data, and reading a search back.
///
/// Only plain data crosses the boundary (§3.3): objects, arrays, strings, finite numbers, booleans
/// and null. These are the values that go the other way from a result: a search, a chapter to
/// resolve, the context to resolve it in, and a page number.
///
/// A search also comes back the other way, from a saved search the app stored. Reading one is
/// forgiving where reading a result is strict: the data is the app's own, and a value whose filter
/// the extension no longer declares, or no longer takes, is dropped rather than failing. That is
/// what keying values by a filter's key rather than its position is for.
library;

import '../models/chapter.dart';
import '../models/media.dart';
import '../models/search.dart';

/// [query] as `search` receives it.
Map<String, Object?> encodeSearchQuery(SearchQuery query) => {
  'text': query.text,
  'filters': {
    for (final MapEntry(:key, :value) in query.filters.values.entries)
      key: encodeFilterValue(value),
  },
};

/// One filter value as the extension receives it: a string, a boolean, or a sort's object.
Object? encodeFilterValue(FilterValue filterValue) => switch (filterValue) {
  TextValue(:final text) => text,
  CheckboxValue(:final checked) => checked,
  TriState() => filterValue.name,
  SelectValue(:final value) => value,
  SortValue(:final value, :final ascending) => {
    'value': value,
    'ascending': ascending,
  },
};

/// [chapter] as `resolveMedia` receives it.
Map<String, Object?> encodeChapterRef(ChapterRef chapter) => {
  'bookKey': chapter.bookKey,
  'chapterKey': chapter.chapterKey,
};

/// [context] as `resolveMedia` receives it.
Map<String, Object?> encodeResolveContext(ResolveContext context) => {
  'purpose': context.purpose.name,
  'network': context.network.name,
};

/// A page number as `getPopular`, `getLatest` and `search` receive it. Pages are numbered from 1.
///
/// Throws [ArgumentError] for a lower number: the app asked for a page that does not exist, which
/// is a bug in the app rather than anything an extension did.
int encodePage(int page) => page >= 1
    ? page
    : throw ArgumentError.value(page, 'page', 'pages are numbered from 1');

/// Reads a search the app stored, against the filters the source declares now.
///
/// A value is kept only when its filter still exists, still takes that kind of value, and the value
/// still differs from the filter's default. Everything else is dropped, so a saved search survives
/// an extension update that adds, removes or reorders filters.
///
/// Throws [FormatException] when [data] is not a search at all, which means the stored value is
/// damaged rather than out of date.
SearchQuery decodeSearchQuery(Object? data, {required List<Filter> filters}) {
  if (data is! Map) {
    throw FormatException('a saved search is an object', data);
  }
  final text = data['text'];
  if (text != null && text is! String) {
    throw FormatException('a saved search\'s text is a string', text);
  }
  final values = data['filters'];
  if (values != null && values is! Map) {
    throw FormatException('a saved search\'s filters are an object', values);
  }
  final declared = {
    for (final filter in valueFilters(filters)) filter.key: filter,
  };
  final kept = <String, FilterValue>{};
  if (values is Map) {
    for (final MapEntry(:key, :value) in values.entries) {
      if (key is! String) continue;
      final filter = declared[key];
      if (filter == null) continue;
      final decoded = _valueFor(filter, value);
      if (decoded == null || decoded == filter.defaultValue) continue;
      kept[key] = decoded;
    }
  }
  return SearchQuery(text: text as String? ?? '', filters: FilterValues(kept));
}

/// [value] as [filter] takes it, or null when it is not a value that filter takes.
FilterValue? _valueFor(ValueFilter filter, Object? value) => switch (filter) {
  TextFilter() => value is String ? TextValue(value) : null,
  CheckboxFilter() => value is bool ? CheckboxValue(value) : null,
  TriStateFilter() => switch (value) {
    'ignore' => TriState.ignore,
    'include' => TriState.include,
    'exclude' => TriState.exclude,
    _ => null,
  },
  SelectFilter(:final options) =>
    value is String && options.any((option) => option.value == value)
        ? SelectValue(value)
        : null,
  SortFilter(:final options) => switch (value) {
    {'value': final String chosen, 'ascending': final bool ascending}
        when options.any((option) => option.value == chosen) =>
      SortValue(value: chosen, ascending: ascending),
    _ => null,
  },
};
