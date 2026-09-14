import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart' show BookOverview;

import 'format.dart';

/// Where the play button starts a book.
enum PlayFrom {
  /// Where it was left, or the beginning of a book never started.
  savedPosition,

  /// The beginning, for a finished book played again.
  start,
}

/// A book's details: its credits and length, where the listener is, its chapters, and what can be
/// done with it.
///
/// Fed with data rather than watching providers, so it can be tested without a database.
class BookDetailsView extends StatelessWidget {
  const BookDetailsView({
    super.key,
    required this.book,
    required this.onPlay,
    required this.onRemove,
  });

  final BookOverview book;
  final ValueChanged<PlayFrom> onPlay;

  /// Called once the listener has confirmed they want the book out of the library.
  final VoidCallback onRemove;

  /// Wider than this, the content stays at a readable measure in the middle of the window.
  static const _maxContentWidth = 720.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = book.progress;
    final finished = progress?.finished ?? false;
    final total = book.totalDurationMs;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Padding rather than a narrower list, so the whole window still scrolls it.
        final side = math.max(
          16.0,
          (constraints.maxWidth - _maxContentWidth) / 2,
        );
        return ListView(
          padding: EdgeInsets.fromLTRB(side, 16, side, 24),
          children: [
            Text(book.title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            if (book.authors.isNotEmpty)
              Text(
                'By ${book.authors.join(', ')}',
                style: theme.textTheme.bodyLarge,
              ),
            if (book.narrators.isNotEmpty)
              Text(
                'Read by ${book.narrators.join(', ')}',
                style: theme.textTheme.bodyMedium,
              ),
            if (total != null)
              Text(formatClock(total), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            if (progress != null) ...[
              if (finished)
                Text('Finished', style: theme.textTheme.bodyMedium)
              else ...[
                if (total != null && total > 0)
                  LinearProgressIndicator(
                    value: (progress.globalPositionMs / total).clamp(0.0, 1.0),
                  ),
                const SizedBox(height: 4),
                Text(
                  total == null
                      ? '${formatClock(progress.globalPositionMs)} listened'
                      : '${formatClock(total - progress.globalPositionMs)} left',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 16),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => onPlay(
                    finished ? PlayFrom.start : PlayFrom.savedPosition,
                  ),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(
                    progress == null
                        ? 'Play'
                        : finished
                        ? 'Play again'
                        : 'Resume',
                  ),
                ),
                if (book.inLibrary)
                  OutlinedButton.icon(
                    onPressed: () => _confirmRemoval(context),
                    icon: const Icon(Icons.remove_circle_outline),
                    label: const Text('Remove from library'),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Chapters', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            // §4.5: a single file's embedded markers are its chapters as far as the listener is
            // concerned, and the one chapter spanning the file would only repeat the book's title.
            if (book.markers.isNotEmpty)
              for (final marker in book.markers)
                _EntryTile(
                  title: marker.title,
                  durationMs: marker.durationMs,
                  listened: marker.listened,
                  current: marker.current && !finished,
                )
            else
              for (final chapter in book.chapters)
                _EntryTile(
                  title: chapter.title,
                  durationMs: chapter.durationMs,
                  listened: chapter.listened,
                  current: chapter.current && !finished,
                ),
          ],
        );
      },
    );
  }

  Future<void> _confirmRemoval(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from library?'),
        content: Text(
          '${book.title} will no longer be in your library. Your progress '
          'is kept and no files are deleted, so adding the book again '
          'brings it back where you left off.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) onRemove();
  }
}

/// One chapter, or embedded marker, in the list.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.title,
    required this.durationMs,
    required this.listened,
    required this.current,
  });

  final String title;
  final int? durationMs;
  final bool listened;

  /// Where the listener is. Not shown for a finished book, where it would only point at the end.
  final bool current;

  @override
  Widget build(BuildContext context) {
    final duration = durationMs;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      selected: current,
      leading: SizedBox.square(
        dimension: 24,
        child: current
            ? const Icon(Icons.graphic_eq, semanticLabel: 'Where you are')
            : listened
            ? Icon(
                Icons.check,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                semanticLabel: 'Listened',
              )
            : null,
      ),
      title: Text(title),
      trailing: duration == null ? null : Text(formatClock(duration)),
    );
  }
}
