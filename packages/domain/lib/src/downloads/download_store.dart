/// Where the download queue is kept (§5.2).
///
/// A service interface, so it lives in the domain (§2.4), exactly as `PlaybackStore` does: the data
/// layer implements it over the `download_task` table and the driver in `downloads` consumes it, and
/// neither has to know about the other.
///
/// The division matters more here than elsewhere. ADR-0007 makes the table the source of truth rather
/// than the transport, precisely because a row survives a process kill and a `WorkManager` job's idea
/// of itself does not. Everything the driver learns — a resolution, a byte count, a failure — is
/// written here before it is acted on, so that a phone killed mid-download comes back knowing what it
/// was doing.
library;

import 'download_candidate.dart';
import 'download_request.dart';
import 'download_state.dart';

/// What the driver needs to know about a task it is about to start.
final class DownloadSubject {
  const DownloadSubject({
    required this.taskId,
    required this.mediaFileId,
    required this.bookId,
    required this.state,
    this.attempts = 0,
    this.request,
    this.expiresAt,
  });

  final int taskId;

  /// The physical file to fetch. What the resolver is asked about, and what the finished bytes
  /// belong to.
  final int mediaFileId;

  /// The book it is part of, for naming the file on disk and for telling the listener whose download
  /// this is.
  final int bookId;

  /// What the task is doing, as the queue last recorded it.
  ///
  /// The driver needs it for one decision above all: a task in [DownloadState.needsResolve] must ask
  /// its source again even if the address it already has looks fresh, because that address is exactly
  /// the one the site just refused.
  final DownloadState state;

  /// How many times this file has already failed in a way that might not fail again.
  ///
  /// The driver needs it to work out how long the next wait should be, and whether there is a next
  /// wait at all — five attempts is what turns a retryable failure into a permanent one (§5.5).
  final int attempts;

  /// The address written down last time, if there is one.
  final DownloadRequest? request;

  /// When that address stops being usable, as the source said.
  final DateTime? expiresAt;

  /// Whether the stored address can still be used, at [now].
  ///
  /// A task with no address at all has nothing to reuse, and one whose source gave no expiry is
  /// taken at its word — a 403 or a 410 will send it back to be resolved if the word was wrong
  /// (§5.4).
  bool hasUsableRequest(DateTime now) =>
      request != null && (expiresAt == null || expiresAt!.isAfter(now));
}

/// A task the queue last recorded as in flight, and the transport's name for it.
///
/// A record rather than a class: it exists only to carry three columns from the table to the
/// reconciler.
typedef InFlightDownload = ({
  int taskId,
  DownloadState state,
  String? transportTaskId,
});

/// Where the queue lives.
abstract interface class DownloadStore {
  /// The tasks that are pending, most wanted first (§5.2).
  ///
  /// Every task that has not finished and is not in flight: queued, held back by the scheduler, and
  /// those whose address went stale and must be asked for again. A held task has to be in here,
  /// because the scheduler is the only thing that can release it and it cannot release what it cannot
  /// see — leaving it out made [DownloadState.waiting] a state nothing ever left.
  Future<List<DownloadCandidate>> readStartable({int limit});

  /// The tasks the queue believes are in flight, with what the transport called each one.
  ///
  /// For the reconciler (§5.2): resolving and processing both happen inside a single pass, so a task
  /// found in either was interrupted, and a downloading task is only really downloading if the
  /// transport still has it.
  Future<List<InFlightDownload>> readInFlight();

  /// How many files are in flight, by source, for the caps the scheduler applies.
  Future<Map<int, int>> countRunningBySource();

  /// Everything the driver needs about [taskId], or null when the task has gone.
  ///
  /// Null is ordinary rather than exceptional: a listener may cancel a book, or remove it from the
  /// library, between a decision being made and the task being acted on.
  Future<DownloadSubject?> readSubject(int taskId);

  /// Moves [taskId] to [state], and records why it is waiting when it is.
  ///
  /// [hold] is cleared by every state that is not `waiting`, so a task that starts moving does not
  /// go on claiming it wants Wi-Fi.
  Future<void> saveState(int taskId, DownloadState state, {DownloadHold? hold});

  /// Writes down the address [taskId] is about to use, and when it stops being good (§5.4).
  Future<void> saveResolution(
    int taskId, {
    required DownloadRequest request,
    DateTime? expiresAt,
  });

  /// Records how far [taskId] has got. [bytesTotal] is written only once the site has said what it
  /// is, so a progress bar never guesses.
  Future<void> saveProgress(
    int taskId, {
    required int bytesDone,
    int? bytesTotal,
  });

  /// Records that [taskId] failed.
  ///
  /// Counts an attempt, keeps [error] for the listener and for a bug report, and takes [retryAt]
  /// from §5.5's schedule — null when the task has no attempts left, which is what turns a retryable
  /// failure into a permanent one.
  Future<void> saveFailure(
    int taskId, {
    required String error,
    required bool permanent,
    DateTime? retryAt,
  });

  /// Remembers what the transport calls [taskId], so the reconciler can match its live tasks to
  /// these rows at the next launch (§5.2). Null forgets it.
  Future<void> saveTransportId(int taskId, String? transportTaskId);

  /// Records that [taskId]'s file is on the device at [localPath], which is what makes a chapter
  /// playable with no network at all (§5.7).
  ///
  /// Writes the file's path and marks the task completed together, so nothing that reads both can
  /// ever see a finished download whose file is not there.
  Future<void> saveCompleted(int taskId, {required String localPath});

  /// The tasks a retry is now due for, at [now] (§5.5).
  Future<List<int>> readRetryDue(DateTime now);
}
