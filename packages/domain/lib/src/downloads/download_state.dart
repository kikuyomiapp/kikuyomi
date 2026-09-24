/// Where one download has got to, and why it is not moving (§5.3).
///
/// A download is per **physical file**, never per chapter (ADR-0007): a chapter spanning three files
/// makes three of these, and an M4B holding thirty chapters makes one, without either case being
/// special. The `download_task` table is the source of truth for all of it, so these values are what
/// a column holds and what survives the app being killed.
///
/// They live here rather than in `downloads` because three packages need the same words: `data` for
/// the column, `downloads` for the state machine, and the app for the screen.
library;

/// The states of §5.3's machine.
///
/// The diagram's two parameterised boxes are split rather than carried as data. `waiting` keeps its
/// reason in [DownloadHold], because a task waiting for Wi-Fi and one waiting for a free slot look
/// identical to the scheduler and different to a person. `failed` is two values, because retryable
/// and permanent failures are not one state that happens to have a flag: one goes back to [queued]
/// after a wait, the other never moves again.
enum DownloadState {
  /// Wanted, and not yet looked at. Where a task starts, and where a retryable failure returns to.
  queued,

  /// Asking the extension where the bytes are. §5.4 resolves just in time, never at enqueue, because
  /// many sources hand out URLs that expire within minutes.
  resolving,

  /// Resolved, and held back by something the task cannot change: the network, free space, or the
  /// concurrency cap. The reason is a [DownloadHold].
  waiting,

  /// Bytes are moving.
  downloading,

  /// Stopped by the listener, and resumable.
  paused,

  /// Its URL was refused or has expired — a 403, a 410, or an `expiresAt` that has passed — so the
  /// snapshot is stale and the extension must be asked again. Distinct from a failure: nothing is
  /// wrong, the address was simply perishable.
  needsResolve,

  /// The bytes have arrived and are being checked, probed and moved into place (§5.2's
  /// post-processor).
  processing,

  /// On the device, validated, and playable with no network at all.
  completed,

  /// Failed in a way that may not fail again: a dropped connection, a 500, a timeout. It returns to
  /// [queued] once its backoff has elapsed, up to the attempt limit.
  failedRetryable,

  /// Failed in a way that will fail again: a 404, a file the post-processor refused, or a retryable
  /// failure that ran out of attempts. It moves no further without the listener asking.
  failedPermanent,

  /// Given up on by the listener. Terminal, and its partial bytes are the transport's to discard.
  cancelled;

  /// Whether this task is done with, one way or another, and the scheduler may forget it.
  bool get isFinished =>
      this == completed || this == failedPermanent || this == cancelled;

  /// Whether the scheduler is counting this task against its concurrency caps.
  bool get holdsASlot =>
      this == resolving || this == downloading || this == processing;

  /// Whether the listener can ask for this one again by hand.
  bool get canRetryByHand =>
      this == failedRetryable || this == failedPermanent || this == paused;
}

/// Why a [DownloadState.waiting] task is not downloading yet (§5.2's scheduler).
///
/// None of these is a failure and none of them counts an attempt: the task is ready and the world is
/// not. They are kept apart so a screen can say "waiting for Wi-Fi" rather than "waiting", which is
/// the difference between a listener knowing what to do and wondering whether the app is stuck.
enum DownloadHold {
  /// The network policy forbids it: Wi-Fi only, and this connection is metered or absent.
  network,

  /// Free space is below the floor the scheduler will not cross (§5.6).
  storage,

  /// The global or per-source concurrency cap is full. The most ordinary reason, and the one that
  /// clears by itself.
  slot,
}
