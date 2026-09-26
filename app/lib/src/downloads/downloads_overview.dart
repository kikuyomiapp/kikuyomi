/// The Downloads screen's list, worked out from the queue's rows (§5.6).
///
/// The queue counts physical files and a listener counts books, the same gap `book_downloads.dart`
/// bridges for one book. This bridges it for all of them: files arrive as a flat list ordered by book
/// and file, and leave grouped, counted and sorted.
///
/// A pure function for the same reason as the other: the arithmetic is where a size adds up wrong and
/// the ordering is where the book being fetched right now ends up below the eleven that finished last
/// week, and neither needs a database or a widget to get wrong.
library;

import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'book_downloads.dart';

/// One book, as the Downloads screen lists it.
final class DownloadedBook {
  const DownloadedBook({
    required this.bookId,
    required this.title,
    required this.files,
    required this.progress,
    required this.bytesOnDevice,
    required this.filesOnDevice,
  });

  final int bookId;
  final String title;

  /// Its files, in the order the source names them, which for most is reading order.
  final List<DownloadEntry> files;

  /// What the whole book's queue comes to, for the line under the title and for the bar.
  final BookDownloads progress;

  /// What it takes on disk, counting only the files that are really here.
  final int bytesOnDevice;

  /// How many of its files are really here. Not the same as [BookDownloads.completed] after a delete
  /// that only half worked, which is exactly the case worth showing honestly.
  final int filesOnDevice;

  /// Whether there is anything to delete.
  bool get hasFilesOnDevice => filesOnDevice > 0;

  /// Whether anything is still expected to happen without the listener doing something.
  bool get isWorking => progress.isWorking;

  /// Whether anything has not finished one way or another: still to come, on its way, held, paused,
  /// or waiting out a backoff.
  ///
  /// Wider than [isWorking], and it is this that decides whether stopping is worth offering. A book
  /// whose files are all queued behind another book's is not working and is very much worth being
  /// able to stop.
  bool get hasUnfinished => files.any((file) => !file.task.state.isFinished);

  /// Whether every file it has a task for gave up.
  bool get hasFailed => progress.failed > 0;
}

/// [entries] as a list of books, most interesting first.
///
/// The order is what is happening, then what needs attention, then everything else by title. A queue
/// is looked at when something is wrong with it or while something is running, and a book downloading
/// now that sorted under Z would be the one thing the screen exists to show and the last thing on it.
List<DownloadedBook> groupDownloads(List<DownloadEntry> entries) {
  final byBook = <int, List<DownloadEntry>>{};
  final titles = <int, String>{};
  for (final entry in entries) {
    byBook.putIfAbsent(entry.bookId, () => []).add(entry);
    titles[entry.bookId] = entry.bookTitle;
  }

  final books = [
    for (final book in byBook.entries)
      DownloadedBook(
        bookId: book.key,
        title: titles[book.key]!,
        files: book.value,
        progress: summariseDownloads([for (final e in book.value) e.task]),
        bytesOnDevice: book.value
            .where((e) => e.isOnDevice)
            .fold(0, (total, e) => total + (e.sizeBytes ?? 0)),
        filesOnDevice: book.value.where((e) => e.isOnDevice).length,
      ),
  ];

  books.sort(_mostInterestingFirst);
  return books;
}

int _mostInterestingFirst(DownloadedBook a, DownloadedBook b) {
  final byRank = _rank(a).compareTo(_rank(b));
  if (byRank != 0) return byRank;
  final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  // Two books with the same title are two rows, and which comes first has to be the same every time
  // or the list reorders itself under the listener's finger.
  return byTitle != 0 ? byTitle : a.bookId.compareTo(b.bookId);
}

int _rank(DownloadedBook book) {
  if (book.isWorking) return 0;
  if (book.hasFailed) return 1;
  return 2;
}

/// What all of [books] take on disk.
int totalBytesOnDevice(List<DownloadedBook> books) =>
    books.fold(0, (total, book) => total + book.bytesOnDevice);

/// A speed as a person reads it: `4.2 MB/s`.
String formatRate(double bytesPerSecond) =>
    '${formatBytes(bytesPerSecond.round())}/s';

/// What to say about one file, in a few words: its state, or its size once it is here.
///
/// [bytesPerSecond] is how fast it is moving right now, when anything knows. It is passed in rather
/// than looked up because it does not live in the database — see `rates.dart` — and because a pure
/// function of both is the only way to test the sentence.
String describeDownloadedFile(DownloadEntry entry, {double? bytesPerSecond}) {
  final size = entry.sizeBytes;
  if (entry.isOnDevice) {
    return size == null ? 'Downloaded' : 'Downloaded · ${formatBytes(size)}';
  }
  return switch (entry.task.state) {
    DownloadState.queued => 'Queued',
    DownloadState.needsResolve => 'Finding it again',
    DownloadState.resolving => 'Finding it',
    DownloadState.downloading => _downloading(entry, bytesPerSecond),
    DownloadState.processing => 'Checking it',
    DownloadState.waiting => switch (entry.task.hold) {
      DownloadHold.network => 'Waiting for Wi-Fi',
      DownloadHold.storage => 'Not enough space',
      DownloadHold.slot || null => 'Waiting its turn',
    },
    DownloadState.paused => 'Paused',
    DownloadState.cancelled => 'Cancelled',
    DownloadState.failedRetryable =>
      entry.task.lastError ?? 'It failed, and will be tried again',
    DownloadState.failedPermanent =>
      entry.task.lastError ?? 'It could not be downloaded',
    // A completed task whose file is not on the device: the row and the disk disagree, which a
    // half-finished delete leaves behind. Saying so is better than showing it as downloaded.
    DownloadState.completed => 'Its file is missing',
  };
}

String _downloading(DownloadEntry entry, double? bytesPerSecond) {
  final speed = bytesPerSecond == null
      ? ''
      : ' · ${formatRate(bytesPerSecond)}';
  final total = entry.task.bytesTotal;
  if (total == null || total <= 0) return 'Downloading$speed';
  final done = entry.task.bytesDone.clamp(0, total);
  return 'Downloading · ${formatBytes(done)} of ${formatBytes(total)}$speed';
}

/// A size as a person reads it: `1.4 GB`, `812 MB`, `4 KB`.
///
/// Powers of 1024 with the units everyone writes for them, which is what every other audiobook player
/// shows and what a listener comparing this with their free space will be reading there too.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // One decimal below ten, none above: "1.4 GB" is worth knowing and "812.3 MB" is noise.
  return value < 10
      ? '${value.toStringAsFixed(1)} ${units[unit]}'
      : '${value.round()} ${units[unit]}';
}
