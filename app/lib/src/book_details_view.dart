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
    required this.onRemove,
    required this.listenedCommands,
    this.downloads = BookDownloads.none,
    this.onDownload,
    this.onStopDownloading,
    this.onAddToLibrary,
    this.onOpenAtSource,
  });

  final BookOverview book;

  /// Where the book's cover is found.
  final CoverFiles covers;

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

  /// Puts a book that has been taken out back in. Null while nothing offers to, which leaves the
  /// action showing what is true and doing nothing.
  final VoidCallback? onAddToLibrary;

  /// Opens the book's page at its source in a browser. Null for a book with no page, which a local
  /// import has none of.
  final VoidCallback? onOpenAtSource;

  /// Wider than this, the content stays at a readable measure in the middle of the window.
  static const _maxContentWidth = 720.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = book.progress;
    final finished = book.finished;
    final total = book.totalDurationMs;
    final description = book.description;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Padding rather than a narrower list, so the whole window still scrolls it.
        final side = math.max(
          16.0,
          (constraints.maxWidth - _maxContentWidth) / 2,
        );
        return ListView(
          // Room at the foot for the floating button, which would otherwise sit on the last chapter.
          padding: EdgeInsets.fromLTRB(side, 16, side, 96),
          children: [
            _Header(book: book, covers: covers),
            const SizedBox(height: 16),
            _ActionStrip(
              inLibrary: book.inLibrary,
              finished: finished,
              downloads: downloads,
              onLibrary: book.inLibrary
                  ? () => _confirmRemoval(context)
                  : onAddToLibrary,
              onDownload: onDownload,
              onStopDownloading: onStopDownloading,
              onFinished: () => finished
                  ? markBookNotFinished(context, listenedCommands)
                  : markBookFinishedWithUndo(context, listenedCommands),
              onOpenAtSource: onOpenAtSource,
            ),
            // Nothing here for a finished book: the strip's lit "Finished" says it, and a book
            // marked finished by hand may never have been started, so there is no progress to draw.
            if (!finished && progress != null) ...[
              const SizedBox(height: 16),
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
            if (!downloads.isEmpty && !downloads.isComplete) ...[
              const SizedBox(height: 16),
              _DownloadProgress(downloads: downloads),
            ],
            if (description != null && description.trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              _Description(text: description.trim()),
            ],
            if (book.genres.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final genre in book.genres)
                    Chip(
                      label: Text(genre),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            Text(_chapterCount(), style: theme.textTheme.titleMedium),
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

  /// How many entries the list below holds, as a heading rather than a bare word.
  ///
  /// The count is the useful part — it is how a listener judges at a glance whether a book is three
  /// hours or sixty chapters — and it is what the heading in Mihon says too.
  String _chapterCount() {
    final count = book.markers.isNotEmpty
        ? book.markers.length
        : book.chapters.length;
    return count == 1 ? '1 chapter' : '$count chapters';
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

/// What the play button says for [book].
///
/// A top-level function because the button itself is the screen's floating one, and this is the one
/// piece of judgement it needs: a book never started is played, one left part-way is resumed, and a
/// finished one is played again from the top.
String playButtonLabel(BookOverview book) => book.finished
    ? 'Play again'
    : book.progress == null
    ? 'Start'
    : 'Resume';

/// Where the play button starts [book].
PlayFrom playButtonFrom(BookOverview book) =>
    book.finished ? PlayFrom.start : PlayFrom.savedPosition;

/// The cover beside what the source says about the book.
///
/// Side by side rather than stacked, so the title, the credits, the length and where the book came
/// from are all above the fold on a phone. Stacked under a full-width cover, everything that
/// identifies a book was pushed off the first screen.
class _Header extends StatelessWidget {
  const _Header({required this.book, required this.covers});

  final BookOverview book;
  final CoverFiles covers;

  /// Big enough to recognise a cover by, small enough to leave the metadata a readable column.
  static const _coverWidth = 120.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = book.totalDurationMs;
    final source = [?book.status, ?book.sourceName].join(' • ');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BookCover(
          file: covers.fileOf(book.coverFileName),
          size: _coverWidth,
          semanticLabel: 'Cover of ${book.title}',
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                book.title,
                style: theme.textTheme.titleLarge,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              if (book.authors.isNotEmpty)
                _MetaRow(
                  icon: Icons.person_outline,
                  text: book.authors.join(', '),
                  semanticLabel: 'Author',
                ),
              if (book.narrators.isNotEmpty)
                _MetaRow(
                  icon: Icons.mic_none,
                  text: book.narrators.join(', '),
                  semanticLabel: 'Narrator',
                ),
              if (total != null)
                _MetaRow(
                  icon: Icons.schedule,
                  text: formatClock(total),
                  semanticLabel: 'Length',
                ),
              if (source.isNotEmpty)
                _MetaRow(
                  icon: Icons.public,
                  text: source,
                  semanticLabel: 'Source',
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One line of the header: a small icon and what it says.
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.text,
    required this.semanticLabel,
  });

  final IconData icon;
  final String text;

  /// What the icon means, for a screen reader. The icon alone is decoration and says nothing.
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
            semanticLabel: semanticLabel,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The row of things that can be done with the book, as icons over labels.
///
/// A strip rather than a wrap of buttons, because these are states as much as actions: whether the
/// book is in the library, whether it is downloaded, whether it is finished. An icon lit or not says
/// that at a glance, where a row of outlined buttons all look alike until they are read.
///
/// A cell with nothing to do is shown all the same, dimmed. Hiding it would move the others under
/// the listener's finger between one visit and the next.
class _ActionStrip extends StatelessWidget {
  const _ActionStrip({
    required this.inLibrary,
    required this.finished,
    required this.downloads,
    required this.onLibrary,
    required this.onDownload,
    required this.onStopDownloading,
    required this.onFinished,
    required this.onOpenAtSource,
  });

  final bool inLibrary;
  final bool finished;
  final BookDownloads downloads;
  final VoidCallback? onLibrary;
  final VoidCallback? onDownload;
  final VoidCallback? onStopDownloading;
  final VoidCallback onFinished;
  final VoidCallback? onOpenAtSource;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Action(
        icon: inLibrary ? Icons.favorite : Icons.favorite_border,
        label: inLibrary ? 'In library' : 'Add to library',
        active: inLibrary,
        onTap: onLibrary,
      ),
      _downloadAction(),
      _Action(
        icon: finished ? Icons.done_all : Icons.check_circle_outline,
        label: finished ? 'Finished' : 'Mark finished',
        active: finished,
        onTap: onFinished,
      ),
      _Action(
        icon: Icons.open_in_new,
        label: 'Source',
        active: false,
        onTap: onOpenAtSource,
      ),
    ],
  );

  /// One cell with three faces, because at any moment there is exactly one thing worth doing: ask
  /// for the book, stop asking, or nothing at all.
  Widget _downloadAction() {
    if (downloads.isComplete) {
      return const _Action(
        icon: Icons.download_done,
        label: 'Downloaded',
        active: true,
        onTap: null,
      );
    }
    if (downloads.isEmpty) {
      return _Action(
        icon: Icons.download_outlined,
        label: 'Download',
        active: false,
        onTap: onDownload,
      );
    }
    return _Action(
      icon: Icons.stop_circle_outlined,
      label: 'Stop',
      active: true,
      onTap: onStopDownloading,
    );
  }
}

/// One cell of the strip.
class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  /// Whether this is a state the book is in, which is what the accent colour says.
  final bool active;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = onTap == null && !active
        ? theme.colorScheme.outlineVariant
        : active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              Icon(icon, color: colour),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: theme.textTheme.labelSmall?.copyWith(color: colour),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the source says about the book, folded to a few lines until it is asked to open.
///
/// Folded by default because a description can run to several paragraphs and the chapters are what
/// most visits are for. The whole box is the target rather than the chevron alone, since a paragraph
/// of text is easier to hit than a small arrow.
class _Description extends StatefulWidget {
  const _Description({required this.text});

  final String text;

  @override
  State<_Description> createState() => _DescriptionState();
}

class _DescriptionState extends State<_Description> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: theme.textTheme.bodyMedium,
              maxLines: _open ? null : 3,
              overflow: _open ? TextOverflow.clip : TextOverflow.ellipsis,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Icon(
                _open ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
                semanticLabel: _open ? 'Show less' : 'Show more',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
