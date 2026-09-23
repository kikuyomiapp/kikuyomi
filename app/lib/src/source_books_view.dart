import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kikuyomi_design_system/kikuyomi_design_system.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

import 'format.dart';
import 'sources/source_books_controller.dart';
import 'sources/source_error_view.dart';

/// A source's books as a grid of covers that fills in as the listener scrolls.
///
/// Fed with a [SourceBooksController] rather than watching providers, so it can be tested with a
/// fake source and no database at all.
///
/// The next page is asked for before the listener reaches the end, so that scrolling does not stop
/// dead at every page boundary. A failure part-way through leaves the books that arrived on screen
/// with the reason underneath, because losing forty books to say one page failed helps nobody.
class SourceBooksView extends StatefulWidget {
  const SourceBooksView({
    super.key,
    required this.controller,
    required this.sourceName,
    required this.onOpen,
    required this.emptyMessage,
  });

  final SourceBooksController controller;

  /// Named in a failure, so a listener knows which source stopped.
  final String sourceName;

  /// A book was tapped: show its details at the source.
  final ValueChanged<BookSummary> onOpen;

  /// Shown when the source answers with no books at all.
  final String emptyMessage;

  @override
  State<SourceBooksView> createState() => _SourceBooksViewState();
}

class _SourceBooksViewState extends State<SourceBooksView> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// How far from the end the next page is asked for: about two rows of covers.
  static const _lookAhead = 600.0;

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - _lookAhead) {
      // The controller ignores this when a page is already in flight, when the source said there is
      // no more, and when the last page failed.
      widget.controller.loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final books = controller.books;

        if (controller.isLoadingFirstPage) {
          return const Center(child: CircularProgressIndicator());
        }
        final error = controller.error;
        if (error != null && books.isEmpty) {
          return SourceErrorView(
            error: error,
            sourceName: widget.sourceName,
            onRetry: controller.retry,
          );
        }
        if (books.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(widget.emptyMessage, textAlign: TextAlign.center),
            ),
          );
        }

        // A page that arrives without filling the viewport would never trigger the scroll listener,
        // so the next one is asked for as soon as the grid has been laid out short.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          if (_scroll.position.maxScrollExtent <= 0) controller.loadMore();
        });

        return CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(12),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.crossAxisExtent;
                  final columns = math.max(2, (width / 180).floor());
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.62,
                    ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final book = books[index];
                      return _BookTile(
                        book: book,
                        onTap: () => widget.onOpen(book),
                      );
                    }, childCount: books.length),
                  );
                },
              ),
            ),
            if (controller.isLoading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
            if (error != null)
              SliverToBoxAdapter(
                child: SourceErrorView(
                  error: error,
                  sourceName: widget.sourceName,
                  onRetry: controller.retry,
                  compact: true,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book, required this.onTap});

  final BookSummary book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credit = book.authors.isNotEmpty
        ? book.authors.first
        : book.narrators.isNotEmpty
        ? book.narrators.first
        : null;
    final duration = book.durationMs;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover.network(
              url: book.coverUrl,
              size: constraints.maxWidth,
              semanticLabel: 'Cover of ${book.title}',
            ),
            const SizedBox(height: 6),
            Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            if (credit != null)
              Text(
                credit,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (duration != null)
              Text(
                formatDuration(Duration(milliseconds: duration)),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
