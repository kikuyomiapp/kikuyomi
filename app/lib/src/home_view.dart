import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart'
    show BookRow, ContinueListeningBook;

import 'format.dart';

/// The home: the books to continue listening to, above the library.
///
/// §2.6 gives Home and Library tabs of their own inside an adaptive shell. Until that shell exists
/// one screen holds both, with Continue Listening first because §1.5 calls it the most important
/// screen in the app.
///
/// Fed with data rather than watching providers, so it can be tested without a database.
class HomeView extends StatelessWidget {
  const HomeView({
    super.key,
    required this.continueListening,
    required this.library,
    required this.emptyMessage,
    required this.onResume,
    required this.onShowDetails,
  });

  final List<ContinueListeningBook> continueListening;
  final List<BookRow> library;

  /// Shown in place of everything else while there are no books at all.
  final String emptyMessage;

  /// A book to continue was tapped: resume it.
  final ValueChanged<int> onResume;

  /// A book in the library was tapped: show its details.
  final ValueChanged<int> onShowDetails;

  @override
  Widget build(BuildContext context) {
    if (continueListening.isEmpty && library.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(emptyMessage, textAlign: TextAlign.center),
        ),
      );
    }
    return CustomScrollView(
      slivers: [
        if (continueListening.isNotEmpty) ...[
          const _SectionHeading('Continue listening'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _Shelf(books: continueListening, onResume: onResume),
            ),
          ),
        ],
        const _SectionHeading('Library'),
        SliverList.builder(
          itemCount: library.length,
          itemBuilder: (context, index) {
            final book = library[index];
            return ListTile(
              leading: const Icon(Icons.headphones),
              title: Text(book.title),
              subtitle: Text(formatClock(book.totalDurationMs ?? 0)),
              onTap: () => onShowDetails(book.id),
            );
          },
        ),
        // Room below the last book, so the "Add book" button never covers it.
        const SliverToBoxAdapter(child: SizedBox(height: 88)),
      ],
    );
  }
}

/// A book on the Continue Listening shelf: where the listener is, and how much is left.
class ContinueListeningCard extends StatelessWidget {
  const ContinueListeningCard({
    super.key,
    required this.book,
    required this.onTap,
  });

  final ContinueListeningBook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = book.totalDurationMs;
    final byline = [
      ?book.author,
      // A file without chapter markers has one chapter named after the book; saying so twice tells
      // the listener nothing.
      if (book.chapterTitle != book.title) book.chapterTitle,
    ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(
                Icons.play_circle_outline,
                size: 40,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (byline.isNotEmpty)
                      Text(
                        byline,
                        style: theme.textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 8),
                    if (total != null && total > 0)
                      LinearProgressIndicator(
                        value: (book.globalPositionMs / total).clamp(0.0, 1.0),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      total == null
                          ? '${formatClock(book.globalPositionMs)} listened'
                          : '${formatClock(total - book.globalPositionMs)} left',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The books to continue, one to a row on a phone and several to a row on a wide window, so the
/// shelf never needs scrolling sideways, which a mouse cannot do by dragging.
class _Shelf extends StatelessWidget {
  const _Shelf({required this.books, required this.onResume});

  final List<ContinueListeningBook> books;
  final ValueChanged<int> onResume;

  static const _minCardWidth = 320.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = math.max(
        1,
        ((width + _gap) / (_minCardWidth + _gap)).floor(),
      );
      // Rounded down, so rounding never pushes the last card of a row onto the next.
      final cardWidth = ((width - _gap * (columns - 1)) / columns)
          .floorToDouble();
      return Wrap(
        spacing: _gap,
        runSpacing: _gap,
        children: [
          for (final book in books)
            SizedBox(
              width: cardWidth,
              child: ContinueListeningCard(
                book: book,
                onTap: () => onResume(book.bookId),
              ),
            ),
        ],
      );
    },
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
