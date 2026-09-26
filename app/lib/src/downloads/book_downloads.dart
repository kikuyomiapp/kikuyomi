/// What a book's downloads come to, as a screen needs to say it (§5.2, §5.6).
///
/// The queue counts physical files and a listener counts books, so something has to turn a handful of
/// `download_task` rows into one sentence and one bar. That is all this does, and it does it as a
/// pure function so the arithmetic — which is where an off-by-one shows up as a progress bar stuck at
/// 99% — can be tested without a database or a widget.
library;

import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// Where a book's download has got to.
final class BookDownloads {
  const BookDownloads({
    required this.files,
    required this.completed,
    required this.active,
    required this.failed,
    this.waitingFor,
    this.bytesDone = 0,
    this.bytesTotal,
  });

  /// A book nobody has asked to download.
  static const none = BookDownloads(
    files: 0,
    completed: 0,
    active: 0,
    failed: 0,
  );

  /// How many files were asked for.
  final int files;

  /// How many are on the device.
  final int completed;

  /// How many are being resolved, fetched or checked right now.
  final int active;

  /// How many have given up, whether or not they will be tried again.
  final int failed;

  /// Why the queue is waiting, when nothing is moving and something is held.
  ///
  /// The whole point of carrying it this far: "waiting for Wi-Fi" is a sentence a listener can act
  /// on, and "waiting" is one that makes them wonder whether the app is stuck.
  final DownloadHold? waitingFor;

  /// Bytes fetched so far, across the book.
  final int bytesDone;

  /// What the book comes to, when every file has said. Null while any of them has not, because a bar
  /// that guesses jumps backwards when the guess is corrected.
  final int? bytesTotal;

  /// Whether anything has been asked for at all.
  bool get isEmpty => files == 0;

  /// Whether every file asked for is here.
  bool get isComplete => files > 0 && completed == files;

  /// Whether anything is still expected to happen without the listener doing something.
  bool get isWorking => active > 0 || waitingFor != null;

  /// How far along the book is, from 0 to 1, or null when it cannot be said.
  ///
  /// Bytes when every file has reported a size, and the count of finished files otherwise. The second
  /// is coarse — a book of three files moves in thirds — but it is honest, and it never goes
  /// backwards, which a byte estimate mixed with guesses would.
  double? get progress {
    if (files == 0) return null;
    final total = bytesTotal;
    if (total != null && total > 0) return (bytesDone / total).clamp(0.0, 1.0);
    return completed / files;
  }
}

/// [tasks] as one book's worth of progress.
BookDownloads summariseDownloads(List<DownloadTaskRow> tasks) {
  if (tasks.isEmpty) return BookDownloads.none;

  var completed = 0;
  var active = 0;
  var failed = 0;
  var bytesDone = 0;
  var bytesTotal = 0;
  var everySizeKnown = true;
  DownloadHold? waitingFor;

  for (final task in tasks) {
    switch (task.state) {
      case DownloadState.completed:
        completed++;
      case DownloadState.resolving:
      case DownloadState.downloading:
      case DownloadState.processing:
        active++;
      case DownloadState.failedRetryable:
      case DownloadState.failedPermanent:
        failed++;
      case DownloadState.waiting:
        // The first reason found is the one shown. They are nearly always the same across a book —
        // one connection, one disk, one set of caps — and a screen listing three of them would be
        // saying the same thing three ways.
        waitingFor ??= task.hold;
      case DownloadState.queued:
      case DownloadState.needsResolve:
      case DownloadState.paused:
      case DownloadState.cancelled:
        break;
    }

    bytesDone += task.state == DownloadState.completed
        // A finished file has all of itself, whatever its last progress report said.
        ? (task.bytesTotal ?? task.bytesDone)
        : task.bytesDone;
    final total = task.bytesTotal;
    if (total == null) {
      everySizeKnown = false;
    } else {
      bytesTotal += total;
    }
  }

  return BookDownloads(
    files: tasks.length,
    completed: completed,
    active: active,
    failed: failed,
    waitingFor: waitingFor,
    bytesDone: bytesDone,
    bytesTotal: everySizeKnown ? bytesTotal : null,
  );
}

/// What to tell the listener about [downloads], in one line.
String describeDownloads(BookDownloads downloads) {
  if (downloads.isEmpty) return 'Not downloaded';
  if (downloads.isComplete) return 'Downloaded';
  final done = '${downloads.completed} of ${downloads.files}';
  if (downloads.active > 0) return 'Downloading $done';
  final waiting = downloads.waitingFor;
  if (waiting != null) {
    return switch (waiting) {
      DownloadHold.network => 'Waiting for Wi-Fi · $done',
      DownloadHold.storage => 'Not enough space · $done',
      DownloadHold.slot => 'Waiting its turn · $done',
    };
  }
  if (downloads.failed > 0) {
    return downloads.failed == 1
        ? 'One file could not be downloaded · $done'
        : '${downloads.failed} files could not be downloaded · $done';
  }
  return 'Queued · $done';
}
