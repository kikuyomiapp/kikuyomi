import 'package:flutter/material.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

/// Asks the listener to set a source's filters, and returns what they chose, or null if they left
/// without applying.
///
/// SourceAPI 1.0 sends only "the filters the listener changed from their defaults", so what comes
/// back holds nothing that is still at its default. That is what lets a saved search survive an
/// extension update: a value is remembered by its filter's key, and a default that changes is not a
/// value anyone chose.
Future<FilterValues?> showSourceFilters(
  BuildContext context, {
  required List<Filter> filters,
  required FilterValues values,
}) => showModalBottomSheet<FilterValues>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => SourceFiltersSheet(filters: filters, values: values),
);

/// The sheet itself, which a test can show without a source behind it.
class SourceFiltersSheet extends StatefulWidget {
  const SourceFiltersSheet({
    super.key,
    required this.filters,
    required this.values,
  });

  final List<Filter> filters;
  final FilterValues values;

  @override
  State<SourceFiltersSheet> createState() => _SourceFiltersSheetState();
}

class _SourceFiltersSheetState extends State<SourceFiltersSheet> {
  late Map<String, FilterValue> _chosen = {...widget.values.values};
  final _text = <String, TextEditingController>{};

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// What a filter is set to now: what the listener chose, or its own default.
  FilterValue? _valueOf(ValueFilter filter) =>
      _chosen[filter.key] ?? filter.defaultValue;

  void _set(ValueFilter filter, FilterValue? value) => setState(() {
    // A value equal to the filter's default is not a choice, and the contract does not send one.
    if (value == null || value == filter.defaultValue) {
      _chosen.remove(filter.key);
    } else {
      _chosen[filter.key] = value;
    }
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final filter in widget.filters) _build(context, filter),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _chosen = {}),
                    child: const Text('Reset'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, FilterValues({..._chosen})),
                    child: const Text('Search'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _build(BuildContext context, Filter filter) => switch (filter) {
    HeaderFilter(:final label) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
    ),
    SeparatorFilter() => const Divider(),
    GroupFilter(:final label, :final filters) => ExpansionTile(
      title: Text(label),
      children: [for (final inner in filters) _build(context, inner)],
    ),
    TextFilter() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: _text.putIfAbsent(
          filter.key,
          () => TextEditingController(
            text: switch (_valueOf(filter)) {
              TextValue(:final text) => text,
              _ => '',
            },
          ),
        ),
        decoration: InputDecoration(labelText: filter.label),
        onChanged: (text) => _set(filter, TextValue(text)),
      ),
    ),
    CheckboxFilter() => CheckboxListTile(
      title: Text(filter.label),
      value: switch (_valueOf(filter)) {
        CheckboxValue(:final checked) => checked,
        _ => false,
      },
      onChanged: (checked) => _set(filter, CheckboxValue(checked ?? false)),
    ),
    TriStateFilter() => ListTile(
      title: Text(filter.label),
      trailing: SegmentedButton<TriState>(
        segments: const [
          ButtonSegment(value: TriState.ignore, label: Text('Any')),
          ButtonSegment(value: TriState.include, label: Text('Yes')),
          ButtonSegment(value: TriState.exclude, label: Text('No')),
        ],
        selected: {
          switch (_valueOf(filter)) {
            final TriState state => state,
            _ => TriState.ignore,
          },
        },
        onSelectionChanged: (chosen) => _set(filter, chosen.first),
      ),
    ),
    SelectFilter(:final options) => ListTile(
      title: Text(filter.label),
      trailing: DropdownButton<String>(
        value: switch (_valueOf(filter)) {
          SelectValue(:final value) => value,
          _ => filter.defaultOption,
        },
        items: [
          for (final option in options)
            DropdownMenuItem(value: option.value, child: Text(option.label)),
        ],
        onChanged: (value) =>
            _set(filter, value == null ? null : SelectValue(value)),
      ),
    ),
    SortFilter(:final options) => _SortTile(
      filter: filter,
      options: options,
      value: switch (_valueOf(filter)) {
        final SortValue sort => sort,
        _ => null,
      },
      onChanged: (value) => _set(filter, value),
    ),
  };
}

/// A sort: which column, and which way round.
///
/// Nothing chosen leaves the site listing results in its own order, which is what the contract says
/// a sort with no default means.
class _SortTile extends StatelessWidget {
  const _SortTile({
    required this.filter,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final SortFilter filter;
  final List<Option> options;
  final SortValue? value;
  final ValueChanged<SortValue?> onChanged;

  @override
  Widget build(BuildContext context) {
    final chosen = value;
    return ListTile(
      title: Text(filter.label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<String?>(
            value: chosen?.value,
            hint: const Text('The source\'s order'),
            items: [
              const DropdownMenuItem(child: Text('The source\'s order')),
              for (final option in options)
                DropdownMenuItem(
                  value: option.value,
                  child: Text(option.label),
                ),
            ],
            onChanged: (value) => onChanged(
              value == null
                  ? null
                  : SortValue(
                      value: value,
                      ascending: chosen?.ascending ?? true,
                    ),
            ),
          ),
          IconButton(
            tooltip: (chosen?.ascending ?? true) ? 'Ascending' : 'Descending',
            icon: Icon(
              (chosen?.ascending ?? true)
                  ? Icons.arrow_upward
                  : Icons.arrow_downward,
            ),
            onPressed: chosen == null
                ? null
                : () => onChanged(
                    SortValue(
                      value: chosen.value,
                      ascending: !chosen.ascending,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
