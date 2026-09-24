import 'package:flutter/material.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'downloads/book_downloads.dart';
import 'downloads/downloads_overview.dart';

/// What the Downloads screen shows, fed with data rather than reading it, so it can be tested without
/// a database, a transport or a disk (§2.10).
///
/// §5.6 asks for total usage, per-book sizes and a way to delete. The unit underneath is a physical
/// file, as it is everywhere in §5.2, so a book opens to its files rather than to its chapters: one
/// file can hold thirty chapters and one chapter can span three files, and a list that promised
/// chapters would be lying about what deleting one does.
class DownloadsView extends StatelessWidget {
  const DownloadsView({
    super.key,
    required this.books,
    required this.busyWith,
    required this.onOpenBook,
    required this.onPauseBook,
    required this.onResumeBook,
    required this.onCancelBook,
    required this.onRetryBook,
    required this.onRemoveBook,
    required this.onRemoveFile,
    required this.onRetryFile,
  });

  /// Every book the download system is holding or fetching, most interesting first.
  final List<DownloadedBook> books;

  /// The book being worked on, so that two taps cannot delete the same files twice. Null when nothing
  /// is under way.
  final int? busyWith;

  final ValueChanged<int> onOpenBook;
  final ValueChanged<DownloadedBook> onPauseBook;
  final ValueChanged<DownloadedBook> onResumeBook;
  final ValueChanged<DownloadedBook> onCancelBook;
  final ValueChanged<DownloadedBook> onRetryBook;

  /// Stops whatever is going, deletes whatever arrived, and takes the book off the list.
  final ValueChanged<DownloadedBook> onRemoveBook;

  /// The same for one file, which is the only way a cancelled or given-up one ever leaves.
  final ValueChanged<DownloadEntry> onRemoveFile;
  final ValueChanged<DownloadEntry> onRetryFile;

  @override
  Widget build(BuildContext context) {
    if (books.isEmpty) return const _NothingDownloaded();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      // The total is a row of the list rather than a header above it, so it scrolls away with
      // everything else instead of taking a strip of a phone screen for ever.
      itemCount: books.length + 1,
      itemBuilder: (context, index) => index == 0
          ? _Total(books: books)
          : _BookTile(
              book: books[index - 1],
              busy: busyWith == books[index - 1].bookId,
              onOpen: onOpenBook,
              onPause: onPauseBook,
              onResume: onResumeBook,
              onCancel: onCancelBook,
              onRetry: onRetryBook,
              onRemove: onRemoveBook,
              onRemoveFile: onRemoveFile,
              onRetryFile: onRetryFile,
            ),
    );
  }
}

class _NothingDownloaded extends StatelessWidget {
  const _NothingDownloaded();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'Nothing downloaded',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Open a book and choose Download to keep it on this device, so it '
            'plays with no network at all.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}

class _Total extends StatelessWidget {
  const _Total({required this.books});

  final List<DownloadedBook> books;

  @override
  Widget build(BuildContext context) {
    final bytes = totalBytesOnDevice(books);
    final onDevice = books.where((book) => book.hasFilesOnDevice).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        bytes == 0
            ? 'Nothing on this device yet'
            : '${formatBytes(bytes)} across '
                  '${onDevice == 1 ? '1 book' : '$onDevice books'}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.busy,
    required this.onOpen,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
    required this.onRemove,
    required this.onRemoveFile,
    required this.onRetryFile,
  });

  final DownloadedBook book;
  final bool busy;
  final ValueChanged<int> onOpen;
  final ValueChanged<DownloadedBook> onPause;
  final ValueChanged<DownloadedBook> onResume;
  final ValueChanged<DownloadedBook> onCancel;
  final ValueChanged<DownloadedBook> onRetry;
  final ValueChanged<DownloadedBook> onRemove;

  /// The same for one file, which is the only way a cancelled or given-up one ever leaves.
  final ValueChanged<DownloadEntry> onRemoveFile;
  final ValueChanged<DownloadEntry> onRetryFile;

  @override
  Widget build(BuildContext context) {
    final progress = book.progress.progress;
    return ExpansionTile(
      title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(_subtitle()),
          if (book.isWorking) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress),
          ],
        ],
      ),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _BookMenu(
              book: book,
              onOpen: onOpen,
              onPause: onPause,
              onResume: onResume,
              onCancel: onCancel,
              onRetry: onRetry,
              onRemove: onRemove,
            ),
      children: [
        for (final file in book.files)
          _FileTile(
            entry: file,
            enabled: !busy,
            onRemove: onRemoveFile,
            onRetry: onRetryFile,
          ),
      ],
    );
  }

  /// The line under the title: what the queue is doing, and what the book takes on disk.
  ///
  /// Both, where both are true. A book half downloaded and still going has a size worth knowing and a
  /// state worth knowing, and showing only one of them is how a listener ends up guessing.
  String _subtitle() {
    final queue = describeDownloads(book.progress);
    if (!book.hasFilesOnDevice) return queue;
    final size = book.bytesOnDevice == 0
        ? '${book.filesOnDevice} of ${book.files.length} on this device'
        : formatBytes(book.bytesOnDevice);
    return book.progress.isComplete ? '$queue · $size' : '$queue · $size here';
  }
}

class _BookMenu extends StatelessWidget {
  const _BookMenu({
    required this.book,
    required this.onOpen,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
    required this.onRemove,
  });

  final DownloadedBook book;
  final ValueChanged<int> onOpen;
  final ValueChanged<DownloadedBook> onPause;
  final ValueChanged<DownloadedBook> onResume;
  final ValueChanged<DownloadedBook> onCancel;
  final ValueChanged<DownloadedBook> onRetry;
  final ValueChanged<DownloadedBook> onRemove;

  bool get _hasPaused =>
      book.files.any((f) => f.task.state == DownloadState.paused);

  /// Whether anything could be paused: on its way, held, or still to start.
  ///
  /// Wider than "working", because a file queued behind another book's is one a listener may well
  /// want to stop before it ever starts.
  bool get _hasPausable => book.files.any(
    (f) => const {
      DownloadState.downloading,
      DownloadState.waiting,
      DownloadState.queued,
    }.contains(f.task.state),
  );

  @override
  Widget build(BuildContext context) => PopupMenuButton<VoidCallback>(
    tooltip: 'What to do with this book',
    onSelected: (action) => action(),
    itemBuilder: (context) => [
      PopupMenuItem(
        value: () => onOpen(book.bookId),
        child: const Text('Open the book'),
      ),
      if (_hasPausable)
        PopupMenuItem(value: () => onPause(book), child: const Text('Pause')),
      if (_hasPaused)
        PopupMenuItem(value: () => onResume(book), child: const Text('Resume')),
      if (book.hasFailed)
        PopupMenuItem(
          value: () => onRetry(book),
          child: const Text('Try again'),
        ),
      if (book.hasUnfinished)
        PopupMenuItem(
          value: () => onCancel(book),
          child: const Text('Stop downloading'),
        ),
      // Always offered, whatever state the book is in. Stopping leaves the rows behind, and a
      // cancelled or given-up row that nothing could remove would sit on this screen for the life of
      // the library. This is the action that always applies: it stops what is going, deletes what
      // arrived, and takes the book off the list.
      PopupMenuItem(
        value: () => onRemove(book),
        child: Text(
          book.hasFilesOnDevice ? 'Delete and remove' : 'Remove from the list',
        ),
      ),
    ],
  );
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.entry,
    required this.enabled,
    required this.onRemove,
    required this.onRetry,
  });

  final DownloadEntry entry;
  final bool enabled;
  final ValueChanged<DownloadEntry> onRemove;
  final ValueChanged<DownloadEntry> onRetry;

  bool get _failed =>
      entry.task.state == DownloadState.failedPermanent ||
      entry.task.state == DownloadState.failedRetryable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 32, right: 8),
      leading: Icon(
        entry.isOnDevice
            ? Icons.check_circle_outline
            : _failed
            ? Icons.error_outline
            : Icons.schedule,
        size: 20,
        color: _failed ? theme.colorScheme.error : theme.colorScheme.outline,
      ),
      title: Text(
        entry.fileKey,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Text(
        describeDownloadedFile(entry),
        maxLines: 2,
        style: theme.textTheme.bodySmall?.copyWith(
          color: _failed ? theme.colorScheme.error : null,
        ),
      ),
      // Removing is offered on every file, in every state. On the device it deletes the file; before
      // then it stops the fetch and takes the row away, which is the only way a cancelled or
      // given-up file ever leaves this screen.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_failed)
            IconButton(
              tooltip: 'Try this file again',
              icon: const Icon(Icons.refresh),
              onPressed: enabled ? () => onRetry(entry) : null,
            ),
          IconButton(
            tooltip: entry.isOnDevice
                ? 'Delete this file'
                : 'Remove this file from the list',
            icon: Icon(entry.isOnDevice ? Icons.delete_outline : Icons.close),
            onPressed: enabled ? () => onRemove(entry) : null,
          ),
        ],
      ),
    );
  }
}
