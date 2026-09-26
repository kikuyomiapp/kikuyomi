/// §5.2's transport, over `background_downloader` (ADR-0007).
///
/// The thin side of the line. "The queue is ours — database-backed, so it survives a process kill and
/// can be inspected, reordered and resumed. The transport is theirs — the part that must talk to
/// `WorkManager` and `URLSession`." So this file translates, and decides almost nothing: what to fetch
/// next, how many at once, what a failure means and when to try again are all settled above it.
///
/// Two settings here are load-bearing, and both are about keeping decisions on our side.
///
/// **No retries.** The package will happily retry a task itself, and if it did, §5.5's attempt count
/// would be wrong and the backoff would be applied twice over — once by it and once by us. So
/// `retries: 0`, and a failure comes straight back to be judged.
///
/// **No network policy.** `requiresWiFi` would have the platform hold a task until Wi-Fi returned,
/// which sounds right and is not: the task would sit invisible to the queue, the Downloads screen
/// could not say why, and §5.2's own network policy would have nothing to apply. The driver holds
/// tasks on a metered connection instead, and this is told to fetch only what may be fetched now.
library;

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_downloads/kikuyomi_downloads.dart';

/// Moves bytes, through whatever mechanism the platform gives.
final class BackgroundTransport implements DownloadTransport {
  BackgroundTransport({bd.FileDownloader? downloader, String? incomingFolder})
    : _downloader = downloader ?? bd.FileDownloader(),
      _incoming = incomingFolder ?? 'incoming_downloads';

  final bd.FileDownloader _downloader;

  /// Where the platform is asked to leave finished files, inside the app's own storage.
  ///
  /// Not where they are kept: §5.2's post-processor checks each one and moves it into place, and a
  /// file that turns out to be a web page must never have been written where the app looks for audio.
  final String _incoming;

  final _reports = StreamController<TransportReport>.broadcast();
  StreamSubscription<bd.TaskUpdate>? _updates;

  @override
  Stream<TransportReport> get reports {
    _listen();
    return _reports.stream;
  }

  void _listen() {
    _updates ??= _downloader.updates.listen(_onUpdate);
  }

  @override
  Future<String> start({
    required int taskId,
    required DownloadRequest request,
    required String fileName,
  }) async {
    _listen();
    final task = bd.DownloadTask(
      // Our own id, so every report maps back without a lookup — which matters most after a restart,
      // when the only thing both sides agree on is what is written down.
      taskId: '$taskId',
      url: request.url,
      headers: request.headers,
      filename: fileName,
      directory: _incoming,
      baseDirectory: bd.BaseDirectory.applicationSupport,
      updates: bd.Updates.statusAndProgress,
      allowPause: true,
      // §5.5 is ours. See the note at the top of this file.
      retries: 0,
    );
    final accepted = await _downloader.enqueue(task);
    if (!accepted) {
      throw StateError('the platform would not take the download');
    }
    return task.taskId;
  }

  @override
  Future<void> pause(int taskId) async {
    final task = await _downloader.taskForId('$taskId');
    if (task is bd.DownloadTask) await _downloader.pause(task);
  }

  @override
  Future<void> cancel(int taskId) async {
    await _downloader.cancelTaskWithId('$taskId');
  }

  @override
  Future<bool> resume(int taskId) async {
    final task = await _downloader.taskForId('$taskId');
    // Gone from the platform's own records, which is what a long enough pause comes to.
    if (task is! bd.DownloadTask) return false;
    // Asked rather than assumed: it depends on the server having offered ranges and on the partial
    // file still being where the platform left it.
    if (!await _downloader.taskCanResume(task)) return false;
    return _downloader.resume(task);
  }

  @override
  Future<Set<String>> carrying() async =>
      (await _downloader.allTaskIds()).toSet();

  /// Stops listening and closes the reports. The app keeps one transport for as long as it runs.
  Future<void> dispose() async {
    await _updates?.cancel();
    _updates = null;
    await _reports.close();
  }

  void _onUpdate(bd.TaskUpdate update) {
    final taskId = int.tryParse(update.task.taskId);
    // A task this app did not enqueue — left over from a previous version, or another part of the app
    // one day. Nothing here can say anything useful about it.
    if (taskId == null) return;

    switch (update) {
      case bd.TaskProgressUpdate(:final progress, :final expectedFileSize):
        // The package puts sentinels below zero in this same field — a paused task, one waiting to
        // retry — and they are states the queue already knows about because it asked for them. Read as
        // a fraction they would be negative bytes.
        if (progress < 0) return;
        // The package reports a fraction; the queue counts bytes. A size of -1 means it does not know
        // yet, and then neither do we, which is exactly what a null total says.
        final total = expectedFileSize > 0 ? expectedFileSize : null;
        _reports.add(
          TransportProgress(
            taskId,
            bytesDone: total == null ? 0 : (progress * total).round(),
            bytesTotal: total,
          ),
        );

      case bd.TaskStatusUpdate(:final status):
        unawaited(_onStatus(taskId, update, status));
    }
  }

  Future<void> _onStatus(
    int taskId,
    bd.TaskStatusUpdate update,
    bd.TaskStatus status,
  ) async {
    switch (status) {
      case bd.TaskStatus.complete:
        final path = await update.task.filePath();
        _reports.add(
          TransportFinished(
            taskId,
            path: path,
            bytesTotal: await _sizeOf(path),
          ),
        );

      case bd.TaskStatus.notFound:
        _reports.add(
          TransportFailed(
            taskId,
            message: 'the file is not there any more',
            permanent: true,
          ),
        );

      case bd.TaskStatus.failed:
        _reports.add(_failureOf(taskId, update));

      // The rest are states the queue already knows about, because it asked for them: a task it
      // paused, a task it cancelled, and the ordinary progress of one it started. Reporting them
      // would tell the driver what it just did.
      case bd.TaskStatus.enqueued:
      case bd.TaskStatus.running:
      case bd.TaskStatus.paused:
      case bd.TaskStatus.canceled:
      case bd.TaskStatus.waitingToRetry:
        break;
    }
  }

  /// How big the file that arrived actually is.
  ///
  /// Asked rather than taken from the last progress report, because for a file small enough to arrive
  /// between two reports there may not have been one: a finished download was being recorded as nought
  /// bytes of a known total, which is a progress bar that never reaches the end. The file on disk is
  /// the one thing that cannot be wrong about its own length.
  static Future<int?> _sizeOf(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException {
      // Reported as finished and not there. §5.2's post-processor is about to refuse it and say so
      // properly, which is a better message than anything this could add.
      return null;
    }
  }

  /// What a failure means, in the queue's vocabulary.
  ///
  /// The status code is what decides it. A 403 or a 410 is the address going stale rather than the
  /// file going wrong (§5.4), which sends the task back to its extension and costs it no attempt. Any
  /// other 4xx is the site refusing for a reason that will not change by asking again — except 408 and
  /// 429, which are the site asking for time.
  TransportFailed _failureOf(int taskId, bd.TaskStatusUpdate update) {
    final code = update.responseStatusCode;
    final message = update.exception?.description ?? 'the download failed';
    if (code == 403 || code == 410) {
      return TransportFailed(taskId, message: message, urlRejected: true);
    }
    final permanent =
        code != null && code >= 400 && code < 500 && code != 408 && code != 429;
    return TransportFailed(taskId, message: message, permanent: permanent);
  }
}
