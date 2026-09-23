import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

import 'providers.dart';
import 'routes.dart';
import 'source_books_view.dart';
import 'sources/source_books_controller.dart';
import 'sources/source_error_view.dart';
import 'sources/source_filters_sheet.dart';
import 'sources/source_problem.dart';

/// One source's catalogue: what it calls popular, and search.
///
/// The extension's runtime starts here, on first use (§3.6), which is why opening this screen can
/// fail before any book has been asked for. That failure is shown like any other.
class SourceScreen extends ConsumerStatefulWidget {
  const SourceScreen({super.key, required this.sourceId});

  final int sourceId;

  @override
  ConsumerState<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends ConsumerState<SourceScreen> {
  final _search = TextEditingController();

  ContentSource? _source;
  Object? _openError;
  SourceBooksController? _books;

  /// The filters the source declares, fetched the first time the button is tapped. A source with no
  /// filters is never asked.
  List<Filter>? _filters;
  var _values = FilterValues.none;
  var _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_openSource());
  }

  @override
  void dispose() {
    _books?.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _openSource() async {
    try {
      final source = await ref
          .read(servicesProvider)
          .openSource(widget.sourceId);
      if (!mounted) return;
      setState(() {
        _source = source;
        _openError = null;
      });
      _reload();
    } catch (error) {
      if (mounted) setState(() => _openError = error);
    }
  }

  /// Starts the list again: a new search, new filters, or the first load.
  void _reload() {
    final source = _source;
    if (source == null) return;
    final previous = _books;
    final query = _query.trim();
    final searching = query.isNotEmpty || !_values.isEmpty;
    final controller = SourceBooksController(
      (page) => searching
          ? source.search(SearchQuery(text: query, filters: _values), page)
          : source.getPopular(page),
    );
    setState(() => _books = controller);
    previous?.dispose();
    unawaited(controller.loadMore());
  }

  Future<void> _chooseFilters() async {
    final source = _source;
    if (source == null) return;
    var filters = _filters;
    if (filters == null) {
      try {
        filters = _filters = await source.getFilters();
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not read this source\'s filters: '
              '${describeSourceProblemBriefly(error, sourceName: _name)}',
            ),
          ),
        );
        return;
      }
    }
    if (!mounted) return;
    final chosen = await showSourceFilters(
      context,
      filters: filters,
      values: _values,
    );
    if (chosen == null || !mounted) return;
    setState(() => _values = chosen);
    _reload();
  }

  String get _name =>
      ref.read(sourceRegistryProvider).describe(widget.sourceId)?.name ??
      'This source';

  @override
  Widget build(BuildContext context) {
    final description = ref
        .watch(sourceRegistryProvider)
        .describe(widget.sourceId);
    final name = description?.name ?? 'Source';
    final hasFilters =
        description?.capabilities.contains(SourceCapability.filters) ?? false;
    final books = _books;
    final openError = _openError;

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          if (hasFilters && _source != null)
            IconButton(
              tooltip: 'Filters',
              icon: Badge(
                isLabelVisible: !_values.isEmpty,
                child: const Icon(Icons.tune),
              ),
              onPressed: _chooseFilters,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SearchBar(
              controller: _search,
              hintText: 'Search $name',
              leading: const Icon(Icons.search),
              trailing: [
                if (_query.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                      _reload();
                    },
                  ),
              ],
              onSubmitted: (text) {
                setState(() => _query = text);
                _reload();
              },
            ),
          ),
        ),
      ),
      body: switch ((openError, books)) {
        (final Object error, _) => SourceErrorView(
          error: error,
          sourceName: name,
          onRetry: _openSource,
        ),
        (_, final SourceBooksController controller) => SourceBooksView(
          controller: controller,
          sourceName: name,
          emptyMessage: _query.trim().isEmpty
              ? '$name has nothing to show here.'
              : 'Nothing at $name matches "${_query.trim()}".',
          onOpen: (book) => SourceBookRoute(
            sourceId: widget.sourceId,
            bookKey: book.key,
          ).push<void>(context),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
