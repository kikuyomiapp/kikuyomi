import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart' show BookOverview, CoverFiles;
import 'package:kikuyomi_design_system/kikuyomi_design_system.dart';

import 'downloads/book_downloads.dart';
import 'format.dart';
import 'listened_commands.dart';

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
/// Each chapter can be marked listened or not from a menu on its row, and the whole book marked
/// finished or not (§4.5). What is marked is what the book's details, Continue Listening and the
/// player all read, so a mark wins over wherever the listener has been. A single file's embedded
/// markers have no menu: §4.5 records listened state for the file's one chapter, not for a marker,
/// so marking the book finished or not is how it is set.
///
/// Fed with data rather than watching providers, so it can be tested without a database.
class BookDetailsView extends StatelessWidget {
  const BookDetailsView({
    super.key,
    required this.book,
    required this.covers,
    required this.onPlay,
    required this.onRemove,
    required this.listenedCommands,
    this.downloads = BookDownloads.none,
    this.onDownload,
    this.onStopDownloading,
  });

  final BookOverview book;

  /// Where the book's cover is found.
  final CoverFiles covers;
  final ValueChanged<PlayFrom> onPlay;

  /// Called once the listener has confirmed they want the book out of the library.
  final VoidCallback onRemove;

  /// Marking chapters, and the whole book, listened or not.
  final ListenedCommands listenedCommands;

  /// How far this book's download has got (§5.2).
  final BookDownloads downloads;

  /// Asks for every file of the book that is not already here. Null where downloading makes no
  /// sense, as it does not for a book whose files are already on this device.
  final VoidCallback? onDownload;

  /// Gives up on what is queued or running.
  final VoidCallback? onStopDownloading;

  /// The button that asks for the book, or says it is already here.
  ///
  /// One button rather than three, because at any moment there is exactly one thing worth doing:
  /// ask for it, stop asking, or nothing at all.
  Widget _downloadButton() {
    if (downloads.isComplete) {
      return OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.download_done),
        label: const Text('Downloaded'),
      );
    }
    if (downloads.isEmpty) {
      return OutlinedButton.icon(
        onPressed: onDownload,
        icon: const Icon(Icons.download_outlined),
        label: const Text('Download'),
      );
    }
    return OutlinedButton.icon(
      onPressed: onStopDownloading,
      icon: const Icon(Icons.stop_circle_outlined),
      label: const Text('Stop downloading'),
    );
  }

  /// Wider than this, the content stays at a readable measure in the middle of the window.
  static const _maxContentWidth = 720.0;

  /// The cover's size wherever there is room for it; a narrower window shows it as wide as it is.
  static const _coverSize = 240.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = book.progress;
    final finished = book.finished;
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
            Center(
              child: BookCover(
                file: covers.fileOf(book.coverFileName),
                size: math.min(
                  _coverSize,
                  math.max(0.0, constraints.maxWidth - 2 * side),
                ),
                semanticLabel: 'Cover of ${book.title}',
              ),
            ),
            const SizedBox(height: 16),
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
            // A book marked finished by hand may never have been started.
            if (finished) ...[
              Text('Finished', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
            ] else if (progress != null) ...[
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
                    finished
                        ? 'Play again'
                        : progress == null
                        ? 'Play'
                        : 'Resume',
                  ),
                ),
                if (finished)
                  OutlinedButton.icon(
                    onPressed: () =>
                        markBookNotFinished(context, listenedCommands),
                    icon: const Icon(Icons.remove_done),
                    label: const Text('Mark as not finished'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () =>
                        markBookFinishedWithUndo(context, listenedCommands),
                    icon: const Icon(Icons.done_all),
                    label: const Text('Mark as finished'),
                  ),
                if (onDownload != null) _downloadButton(),
                if (book.inLibrary)
                  OutlinedButton.icon(
                    onPressed: () => _confirmRemoval(context),
                    icon: const Icon(Icons.remove_circle_outline),
                    label: const Text('Remove from library'),
                  ),
              ],
            ),
            if (!downloads.isEmpty && !downloads.isComplete) ...[
              const SizedBox(height: 16),
              _DownloadProgress(downloads: downloads),
            ],
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
                  onMark: (listened) => markChapterListened(
                    context,
                    listenedCommands,
                    chapterId: chapter.chapterId,
                    listened: listened,
                  ),
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
    this.onMark,
  });

  final String title;
  final int? durationMs;
  final bool listened;

  /// Where the listener is. Not shown for a finished book, where it would only point at the end.
  final bool current;

  /// Marks the chapter listened, or with false not listened, from the row's menu. Null for a row
  /// with no listened state of its own to set, which has no menu.
  final ValueChanged<bool>? onMark;

  @override
  Widget build(BuildContext context) {
    final duration = durationMs;
    final onMark = this.onMark;
    final length = duration == null ? null : Text(formatClock(duration));
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
      trailing: onMark == null
          ? length
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ?length,
                // A button of its own, rather than a long press on the row, so the menu is found and
                // reached the same way by mouse, touch and keyboard, and a screen reader names it.
                PopupMenuButton<bool>(
                  tooltip: 'Options for $title',
                  onSelected: onMark,
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: !listened,
                      child: Text(
                        listened ? 'Mark as not listened' : 'Mark as listened',
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// What a book's download is doing, under the buttons.
///
/// A bar and a sentence. The sentence carries the reason the queue is waiting, because "waiting for
/// Wi-Fi" is something a listener can act on and "waiting" is something that makes them wonder
/// whether the app has stopped.
class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.downloads});

  final BookDownloads downloads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = downloads.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A determinate bar where the sizes are known, and a moving one where they are not: a bar
        // that guesses would jump backwards the moment the guess was corrected.
        // Determinate where the sizes are known, and a moving bar where they are not: a bar that
        // guessed would jump backwards the moment the guess was corrected.
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 6),
        Text(
          describeDownloads(downloads),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
