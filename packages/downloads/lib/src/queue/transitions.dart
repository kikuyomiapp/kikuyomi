/// §5.3's state machine: what may happen to a download, and what it becomes.
///
/// The whole point of ADR-0007's division of labour is that this part is ours and pure. The transport
/// moves bytes and cannot be unit tested; the decisions about what a task does next can be, and they
/// are the part that goes wrong. So every move a download can make is named here, and anything not
/// named is refused rather than quietly allowed.
///
/// The machine is deliberately total: [advance] never throws. An event that makes no sense for the
/// state it arrives in returns null, which the caller reads as "ignore this". That matters because
/// the events are not all ours — a progress report or a completion can arrive from the transport
/// after the listener has already cancelled, and a machine that threw would turn a race into a crash.
library;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// Something that happens to a download.
///
/// Split by where it comes from, because that is what decides whether it can be trusted to be timely:
/// the scheduler's decisions are synchronous with the queue, while the transport's reports and the
/// listener's taps arrive whenever they arrive.
sealed class DownloadEvent {
  const DownloadEvent();
}

/// The scheduler has picked this task up and is about to ask the extension where the bytes are.
final class DownloadResolutionStarted extends DownloadEvent {
  const DownloadResolutionStarted();
}

/// The extension answered: there is a URL, and the task is ready to move bytes.
final class DownloadResolved extends DownloadEvent {
  const DownloadResolved();
}

/// The task is ready but something outside it is in the way (§5.2's caps and policies).
final class DownloadHeld extends DownloadEvent {
  const DownloadHeld(this.reason);

  final DownloadHold reason;
}

/// Whatever was in the way has gone: a slot opened, Wi-Fi came back, space was freed.
final class DownloadReleased extends DownloadEvent {
  const DownloadReleased();
}

/// The transport has the task and bytes are moving.
final class DownloadStarted extends DownloadEvent {
  const DownloadStarted();
}

/// The listener asked for this one to stop, and to be resumable.
final class DownloadPaused extends DownloadEvent {
  const DownloadPaused();
}

/// The listener asked for it to carry on.
final class DownloadResumed extends DownloadEvent {
  const DownloadResumed();
}

/// The address went stale: a 403, a 410, or an `expiresAt` that has passed (§5.4).
///
/// Not a failure. The extension is asked again, and nothing counts against the attempt limit, because
/// a signed URL expiring is the source working as designed rather than anything going wrong.
final class DownloadUrlRejected extends DownloadEvent {
  const DownloadUrlRejected();
}

/// Every byte has arrived, and the post-processor can check it (§5.2).
final class DownloadBytesArrived extends DownloadEvent {
  const DownloadBytesArrived();
}

/// The post-processor is satisfied: the file is what it claimed to be and is in its final place.
final class DownloadProcessed extends DownloadEvent {
  const DownloadProcessed();
}

/// Something went wrong.
///
/// [permanent] separates a 404 or a file the post-processor refused from a dropped connection. A
/// retryable failure that has used its last attempt is passed here as permanent: running out of
/// attempts is what turns one into the other, and that is the scheduler's judgement, not the
/// machine's.
final class DownloadFailed extends DownloadEvent {
  const DownloadFailed({required this.permanent});

  final bool permanent;
}

/// A retryable failure's backoff has elapsed, so it may queue again (§5.5).
final class DownloadRetryDue extends DownloadEvent {
  const DownloadRetryDue();
}

/// The listener gave up on this one.
final class DownloadCancelled extends DownloadEvent {
  const DownloadCancelled();
}

/// What [from] becomes when [event] happens to it, or null when the event does not apply.
///
/// Null is the ordinary answer for a late report, not an error: the transport may report progress on
/// a task the listener cancelled a moment ago, and the right response is to do nothing.
DownloadState? advance(DownloadState from, DownloadEvent event) {
  // Three things may happen to a task in almost any state, so they are answered before the rest.
  switch (event) {
    // Giving up works from anywhere that has not already finished. Cancelling a completed download
    // would be a way to lose a file the listener has, which is what deleting is for.
    case DownloadCancelled() when !from.isFinished:
      return DownloadState.cancelled;
    // A failure can arrive from any state that is still going. A finished task cannot fail.
    case DownloadFailed(:final permanent) when !from.isFinished:
      return permanent
          ? DownloadState.failedPermanent
          : DownloadState.failedRetryable;
    default:
      break;
  }

  return switch ((from, event)) {
    // The ordinary path, in order.
    (DownloadState.queued, DownloadResolutionStarted()) =>
      DownloadState.resolving,
    (DownloadState.needsResolve, DownloadResolutionStarted()) =>
      DownloadState.resolving,
    (DownloadState.resolving, DownloadResolved()) => DownloadState.waiting,
    (DownloadState.waiting, DownloadReleased()) => DownloadState.downloading,
    // The scheduler may also hand a resolved task straight to the transport when nothing is in the
    // way, without a waiting state nobody would ever see.
    (DownloadState.resolving, DownloadStarted()) => DownloadState.downloading,
    (DownloadState.waiting, DownloadStarted()) => DownloadState.downloading,
    (DownloadState.downloading, DownloadBytesArrived()) =>
      DownloadState.processing,
    (DownloadState.processing, DownloadProcessed()) => DownloadState.completed,

    // Held back after resolving, or held again while waiting for a different reason.
    (DownloadState.resolving, DownloadHeld()) => DownloadState.waiting,
    (DownloadState.waiting, DownloadHeld()) => DownloadState.waiting,

    // Pausing and resuming. The diagram draws this against `downloading`; `waiting` is allowed too,
    // because a listener who pauses a book expects everything in it to stop, not just the one file
    // that happens to be moving.
    (DownloadState.downloading, DownloadPaused()) => DownloadState.paused,
    (DownloadState.waiting, DownloadPaused()) => DownloadState.paused,
    (DownloadState.queued, DownloadPaused()) => DownloadState.paused,
    // Resuming goes back to the queue rather than straight to the transport: the URL may have
    // expired while it sat there, and the caps may be full now. The scheduler decides afresh.
    (DownloadState.paused, DownloadResumed()) => DownloadState.queued,

    // A stale URL is not a failure (§5.4).
    (DownloadState.downloading, DownloadUrlRejected()) =>
      DownloadState.needsResolve,
    (DownloadState.waiting, DownloadUrlRejected()) =>
      DownloadState.needsResolve,
    (DownloadState.resolving, DownloadUrlRejected()) =>
      DownloadState.needsResolve,

    // A retryable failure waits out its backoff and joins the queue again (§5.5).
    (DownloadState.failedRetryable, DownloadRetryDue()) => DownloadState.queued,

    // Anything else is a report that no longer applies.
    _ => null,
  };
}

/// Whether [event] would move a task in [from] at all.
///
/// For a caller that wants to ask before acting — a screen deciding whether to offer Pause, say —
/// rather than move and look at the answer.
bool canAdvance(DownloadState from, DownloadEvent event) =>
    advance(from, event) != null;
