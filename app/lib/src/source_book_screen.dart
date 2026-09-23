import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

import 'providers.dart';
import 'routes.dart';
import 'source_book_view.dart';
import 'sources/source_error_view.dart';
import 'sources/source_problem.dart';

/// A book at a source, and the button that puts it in the library.
///
/// Its details and its chapters are fetched together, because a listener deciding whether to add a
/// book wants to see what is in it, and because they are what adding it writes.
class SourceBookScreen extends ConsumerStatefulWidget {
  const SourceBookScreen({
    super.key,
    required this.sourceId,
    required this.bookKey,
  });

  final int sourceId;
  final String bookKey;

  @override
  ConsumerState<SourceBookScreen> createState() => _SourceBookScreenState();
}

class _SourceBookScreenState extends ConsumerState<SourceBookScreen> {
  BookDetails? _details;
  List<ChapterInfo>? _chapters;
  Object? _error;
  var _loading = true;
  var _adding = false;
  int? _bookId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await ref
          .read(servicesProvider)
          .previewSourceBook(widget.sourceId, widget.bookKey);
      if (!mounted) return;
      setState(() {
        _details = preview.details;
        _chapters = preview.chapters;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// Adds the book, or, once it is in the library, opens its details, where it behaves exactly like
  /// a local book.
  Future<void> _add() async {
    final bookId = _bookId;
    if (bookId != null) {
      await BookRoute(bookId: bookId).push<void>(context);
      return;
    }
    final details = _details;
    final chapters = _chapters;
    if (details == null || chapters == null) return;
    setState(() => _adding = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final added = await ref
          .read(servicesProvider)
          .addSourceBook(
            sourceId: widget.sourceId,
            details: details,
            chapters: chapters,
          );
      if (!mounted) return;
      setState(() {
        _bookId = added;
        _adding = false;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('Added ${details.title} to the library'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => BookRoute(bookId: added).push<void>(context),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _adding = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Could not add the book: '
            '${describeSourceProblemBriefly(error, sourceName: _name)}',
          ),
        ),
      );
    }
  }

  String get _name =>
      ref.read(sourceRegistryProvider).describe(widget.sourceId)?.name ??
      'This source';

  @override
  Widget build(BuildContext context) {
    final details = _details;
    final chapters = _chapters;
    final error = _error;
    final webUrl = details?.webUrl;

    return Scaffold(
      appBar: AppBar(title: Text(details?.title ?? _name)),
      body: switch ((error, details, chapters)) {
        (final Object error, _, _) => SourceErrorView(
          error: error,
          sourceName: _name,
          onRetry: _load,
        ),
        (_, final BookDetails details, final List<ChapterInfo> chapters) =>
          SourceBookView(
            details: details,
            chapters: chapters,
            inLibrary: _bookId != null,
            adding: _adding,
            onAdd: _add,
            onOpenAtSource: webUrl == null
                ? null
                : () => openInBrowser(context, webUrl),
          ),
        _ when _loading => const Center(child: CircularProgressIndicator()),
        _ => const Center(child: Text('Nothing to show for this book.')),
      },
    );
  }
}
