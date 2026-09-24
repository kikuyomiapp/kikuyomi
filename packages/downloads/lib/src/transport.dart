/// The line ADR-0007 draws: what moves bytes, and nothing else.
///
/// "The queue is ours — database-backed, so it survives a process kill and can be inspected,
/// reordered and resumed. The transport is theirs — the part that must talk to `WorkManager` and
/// `URLSession`. Keeping the state machine on our side of the line means the interesting logic is
/// pure Dart and unit-testable, and the untestable platform part is as thin as it can be."
///
/// So this interface is deliberately small. It takes a request and a name, it reports what happens,
/// and it can be told to stop. Everything else — what to fetch next, how many at once, what a failure
/// means, when to try again — is decided on our side and never asked of it.
library;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// Something the transport has to say about a task it is carrying.
///
/// Every report names the task by the id we gave it rather than by the transport's own, because the
/// driver's whole vocabulary is task ids and a report that had to be looked up first would be one
/// more thing to get wrong after a restart.
sealed class TransportReport {
  const TransportReport(this.taskId);

  final int taskId;
}

/// Bytes have moved.
final class TransportProgress extends TransportReport {
  const TransportProgress(
    super.taskId, {
    required this.bytesDone,
    this.bytesTotal,
  });

  final int bytesDone;

  /// What the whole file is, once the site has said. Null before then, and the driver writes it down
  /// only when it is known, so a progress bar never guesses.
  final int? bytesTotal;
}

/// Every byte has arrived, and the file is at [path].
///
/// The path is where the transport put it, which is not where it will live: §5.2's post-processor
/// checks it and moves it into place. Reporting the raw path rather than the final one keeps the
/// transport from needing to know the app's storage layout.
final class TransportFinished extends TransportReport {
  const TransportFinished(super.taskId, {required this.path, this.bytesTotal});

  final String path;
  final int? bytesTotal;
}

/// It went wrong.
final class TransportFailed extends TransportReport {
  const TransportFailed(
    super.taskId, {
    required this.message,
    this.permanent = false,
    this.urlRejected = false,
  });

  /// What the transport or the site said, for the listener and for a bug report.
  final String message;

  /// Whether trying the same thing again would fail the same way: a 404, a file the disk refused.
  final bool permanent;

  /// Whether the address itself was the problem — a 403 or a 410 — rather than the fetch (§5.4).
  ///
  /// Kept apart from [permanent] because it is not a failure at all: many sources hand out signed
  /// URLs that expire, so the answer is to ask the extension again rather than to count an attempt
  /// against the file.
  final bool urlRejected;
}

/// What actually moves the bytes.
///
/// One implementation, over `background_downloader`, which delegates to WorkManager on Android, a
/// background `URLSession` on iOS and an in-process isolate on desktop (ADR-0007). Everything above
/// this interface is pure Dart and tested with a fake.
abstract interface class DownloadTransport {
  /// Begins fetching [request] for [taskId], to be stored under [fileName].
  ///
  /// Returns whatever the transport calls the job, which is written down so that the reconciler can
  /// match its live tasks to our rows at the next launch (§5.2). [fileName] is a name, not a path:
  /// where downloads live is the transport implementation's business, because only it knows what the
  /// platform will let it keep.
  Future<String> start({
    required int taskId,
    required DownloadRequest request,
    required String fileName,
  });

  /// Stops [taskId] and keeps what has arrived, if the platform can.
  Future<void> pause(int taskId);

  /// Stops [taskId] and throws away what has arrived.
  Future<void> cancel(int taskId);

  /// Everything the transport has to say, for as long as the app runs.
  Stream<TransportReport> get reports;

  /// The transport's own names for the tasks it is still carrying: enqueued, running, or waiting.
  ///
  /// The one question worth asking it, and only at startup. ADR-0007 makes the table the source of
  /// truth precisely because the transport's idea of itself does not survive a process kill — but the
  /// converse is what the reconciler needs (§5.2). A row that says `downloading` after a restart is
  /// either a job the platform really did keep going or a job that died with the process, and this is
  /// the only thing that can tell the two apart.
  Future<Set<String>> carrying();
}
