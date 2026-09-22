/// Search and its filters: SourceAPI 1.0's `SearchQuery`, `Filter` and `FilterValues`.
///
/// The filter kinds are Mihon's (§3.4), but values are keyed by each filter's key rather than by
/// position, so an extension update that adds or reorders filters never misreads a saved search.
library;

import '../equality.dart';

/// A search, as `search` is asked for it.
final class SearchQuery {
  const SearchQuery({this.text = '', this.filters = FilterValues.none});

  /// What the listener typed. May be empty when only filters are set.
  final String text;

  /// Only the filters the listener changed from their defaults.
  final FilterValues filters;

  @override
  bool operator ==(Object other) =>
      other is SearchQuery && other.text == text && other.filters == filters;

  @override
  int get hashCode => Object.hash(text, filters);

  @override
  String toString() => 'SearchQuery("$text", $filters)';
}

/// One choice of a select or sort filter.
final class Option {
  const Option({required this.value, required this.label});

  /// What the source receives when the option is chosen. Unique within its filter.
  final String value;

  /// What the listener sees.
  final String label;

  @override
  bool operator ==(Object other) =>
      other is Option && other.value == value && other.label == label;

  @override
  int get hashCode => Object.hash(value, label);

  @override
  String toString() => 'Option($value, "$label")';
}

/// One entry of a source's filter list.
///
/// Every value-carrying filter is a [ValueFilter], with a key unique across the whole list, groups
/// included. [HeaderFilter], [SeparatorFilter] and [GroupFilter] only arrange the others.
sealed class Filter {
  const Filter();
}

/// A heading between filters.
final class HeaderFilter extends Filter {
  const HeaderFilter({required this.label});

  final String label;

  @override
  bool operator ==(Object other) =>
      other is HeaderFilter && other.label == label;

  @override
  int get hashCode => label.hashCode;

  @override
  String toString() => 'HeaderFilter("$label")';
}

/// A line between filters.
final class SeparatorFilter extends Filter {
  const SeparatorFilter();

  @override
  bool operator ==(Object other) => other is SeparatorFilter;

  @override
  int get hashCode => (SeparatorFilter).hashCode;

  @override
  String toString() => 'SeparatorFilter()';
}

/// Filters gathered under one label. A group holds no groups: groups are one level deep.
final class GroupFilter extends Filter {
  GroupFilter({required this.label, required List<Filter> filters})
    : filters = List.unmodifiable(filters);

  final String label;
  final List<Filter> filters;

  @override
  bool operator ==(Object other) =>
      other is GroupFilter &&
      other.label == label &&
      listEquals(other.filters, filters);

  @override
  int get hashCode => Object.hash(label, Object.hashAll(filters));

  @override
  String toString() => 'GroupFilter("$label", ${filters.length} filters)';
}

/// A filter the listener sets a value for, sent to the source under [key].
sealed class ValueFilter extends Filter {
  const ValueFilter();

  /// Unique across the source's whole filter list, groups included.
  String get key;
  String get label;

  /// The value the filter starts with. A search sends only values that differ from it.
  FilterValue? get defaultValue;
}

/// Free text.
final class TextFilter extends ValueFilter {
  const TextFilter({
    required this.key,
    required this.label,
    this.defaultText = '',
  });

  @override
  final String key;
  @override
  final String label;

  /// Empty when the source gives no default.
  final String defaultText;

  @override
  TextValue get defaultValue => TextValue(defaultText);

  @override
  bool operator ==(Object other) =>
      other is TextFilter &&
      other.key == key &&
      other.label == label &&
      other.defaultText == defaultText;

  @override
  int get hashCode => Object.hash(key, label, defaultText);

  @override
  String toString() => 'TextFilter($key, "$label")';
}

/// On or off.
final class CheckboxFilter extends ValueFilter {
  const CheckboxFilter({
    required this.key,
    required this.label,
    this.defaultChecked = false,
  });

  @override
  final String key;
  @override
  final String label;

  /// Off when the source gives no default.
  final bool defaultChecked;

  @override
  CheckboxValue get defaultValue => CheckboxValue(defaultChecked);

  @override
  bool operator ==(Object other) =>
      other is CheckboxFilter &&
      other.key == key &&
      other.label == label &&
      other.defaultChecked == defaultChecked;

  @override
  int get hashCode => Object.hash(key, label, defaultChecked);

  @override
  String toString() => 'CheckboxFilter($key, "$label")';
}

/// Ignore, include or exclude, such as a genre.
final class TriStateFilter extends ValueFilter {
  const TriStateFilter({
    required this.key,
    required this.label,
    this.defaultValue = TriState.ignore,
  });

  @override
  final String key;
  @override
  final String label;

  /// [TriState.ignore] when the source gives no default.
  @override
  final TriState defaultValue;

  @override
  bool operator ==(Object other) =>
      other is TriStateFilter &&
      other.key == key &&
      other.label == label &&
      other.defaultValue == defaultValue;

  @override
  int get hashCode => Object.hash(key, label, defaultValue);

  @override
  String toString() => 'TriStateFilter($key, "$label")';
}

/// One of a list of options.
final class SelectFilter extends ValueFilter {
  /// [options] must not be empty. [defaultOption] must be the value of one of them, and is the
  /// first option's when not given.
  SelectFilter({
    required this.key,
    required this.label,
    required List<Option> options,
    String? defaultOption,
  }) : options = List.unmodifiable(options),
       defaultOption =
           defaultOption ??
           (options.isEmpty
               ? throw ArgumentError.value(options, 'options', 'is empty')
               : options.first.value);

  @override
  final String key;
  @override
  final String label;

  /// At least one, with no two sharing a value.
  final List<Option> options;

  /// The value of the option chosen at first.
  final String defaultOption;

  @override
  SelectValue get defaultValue => SelectValue(defaultOption);

  @override
  bool operator ==(Object other) =>
      other is SelectFilter &&
      other.key == key &&
      other.label == label &&
      other.defaultOption == defaultOption &&
      listEquals(other.options, options);

  @override
  int get hashCode =>
      Object.hash(key, label, defaultOption, Object.hashAll(options));

  @override
  String toString() =>
      'SelectFilter($key, "$label", ${options.length} options)';
}

/// An order to list results in, ascending or descending.
final class SortFilter extends ValueFilter {
  SortFilter({
    required this.key,
    required this.label,
    required List<Option> options,
    this.defaultValue,
  }) : options = List.unmodifiable(options);

  @override
  final String key;
  @override
  final String label;

  /// At least one, with no two sharing a value.
  final List<Option> options;

  /// Null when the source gives no default: no order is chosen, and the site lists results in its
  /// own.
  @override
  final SortValue? defaultValue;

  @override
  bool operator ==(Object other) =>
      other is SortFilter &&
      other.key == key &&
      other.label == label &&
      other.defaultValue == defaultValue &&
      listEquals(other.options, options);

  @override
  int get hashCode =>
      Object.hash(key, label, defaultValue, Object.hashAll(options));

  @override
  String toString() => 'SortFilter($key, "$label", ${options.length} options)';
}

/// Every filter of [filters] that carries a value, in the order they are declared and including
/// those inside groups.
///
/// Values are keyed by a filter's key wherever it sits, so this is the list a saved search, and the
/// screen that sets one, work from.
Iterable<ValueFilter> valueFilters(Iterable<Filter> filters) sync* {
  for (final filter in filters) {
    if (filter is ValueFilter) {
      yield filter;
    } else if (filter is GroupFilter) {
      yield* valueFilters(filter.filters);
    }
  }
}

/// The value of one filter, of the kind that filter takes.
///
/// A text filter's and a select filter's values are both strings once they cross to the extension,
/// and so is a tri-state; they are told apart here so that a value can be checked against the
/// filter it is for.
sealed class FilterValue {
  const FilterValue();
}

/// A [TextFilter]'s value.
final class TextValue extends FilterValue {
  const TextValue(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is TextValue && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'TextValue("$text")';
}

/// A [CheckboxFilter]'s value.
final class CheckboxValue extends FilterValue {
  const CheckboxValue(this.checked);

  final bool checked;

  @override
  bool operator ==(Object other) =>
      other is CheckboxValue && other.checked == checked;

  @override
  int get hashCode => checked.hashCode;

  @override
  String toString() => 'CheckboxValue($checked)';
}

/// A [TriStateFilter]'s value.
enum TriState implements FilterValue { ignore, include, exclude }

/// A [SelectFilter]'s value: the chosen option's value.
final class SelectValue extends FilterValue {
  const SelectValue(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is SelectValue && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SelectValue($value)';
}

/// A [SortFilter]'s value: the chosen option's value, and the direction.
final class SortValue extends FilterValue {
  const SortValue({required this.value, required this.ascending});

  final String value;
  final bool ascending;

  @override
  bool operator ==(Object other) =>
      other is SortValue &&
      other.value == value &&
      other.ascending == ascending;

  @override
  int get hashCode => Object.hash(value, ascending);

  @override
  String toString() =>
      'SortValue($value, ${ascending ? 'ascending' : 'descending'})';
}

/// Filter values, keyed by each filter's key.
final class FilterValues {
  FilterValues(Map<String, FilterValue> values)
    : values = Map.unmodifiable(values);

  const FilterValues._none() : values = const {};

  /// No values: every filter at its default.
  static const none = FilterValues._none();

  final Map<String, FilterValue> values;

  bool get isEmpty => values.isEmpty;

  /// The value set for the filter with [key], or null when it is at its default.
  FilterValue? operator [](String key) => values[key];

  @override
  bool operator ==(Object other) =>
      other is FilterValues && mapEquals(other.values, values);

  @override
  int get hashCode => mapHash(values);

  @override
  String toString() => 'FilterValues($values)';
}
