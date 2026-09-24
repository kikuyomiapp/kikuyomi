/// How long a failed download waits before trying again (§5.5).
///
/// "Retries use exponential backoff with jitter, respect `Retry-After`, and give up after five
/// attempts."
///
/// The reason this is worth writing down rather than sprinkling `Duration`s through the scheduler is
/// the third clause of §5.5: a per-source circuit breaker exists so the app does not hammer a site
/// that has started refusing it. Backoff is the same idea one task at a time, and a volunteer-run
/// site being retried by a hundred installs at once is exactly what jitter is for.
library;

import 'dart:math';

/// The waiting schedule for retryable failures.
final class DownloadBackoff {
  const DownloadBackoff({
    this.first = const Duration(seconds: 5),
    this.ceiling = const Duration(minutes: 30),
    this.maxAttempts = 5,
    this.longestRetryAfter = const Duration(hours: 1),
  });

  /// The wait after the first failure. Each later one doubles it, up to [ceiling].
  final Duration first;

  /// The longest the schedule itself will ever ask for. A download that has failed five times is not
  /// going to be fixed by waiting a day, and the listener can ask again by hand.
  final Duration ceiling;

  /// How many attempts a task gets before a retryable failure becomes a permanent one (§5.5).
  final int maxAttempts;

  /// The longest a site's own `Retry-After` will be honoured.
  ///
  /// Respecting it is the polite thing and the contract's own advice, but a header asking for a day
  /// would strand a queue silently. Past this the task is left to the listener instead.
  final Duration longestRetryAfter;

  /// How long to wait after [attempts] failures, or null when there is nothing left to wait for.
  ///
  /// Null means this task has spent its attempts: the caller turns the retryable failure into a
  /// permanent one, because deciding that is the scheduler's business and not the state machine's.
  ///
  /// [retryAfter] is what the site asked for, when it asked. It is treated as a floor rather than an
  /// answer: a server saying "wait 60 seconds" on a first failure is telling us something the
  /// schedule does not know, but one saying "wait one second" on a fifth is not a reason to ignore
  /// what the schedule has learned.
  ///
  /// [random] is taken so a test can pin the jitter. Left out, it is [Random.new].
  Duration? after(int attempts, {Duration? retryAfter, Random? random}) {
    if (attempts >= maxAttempts) return null;
    final doublings = attempts < 1 ? 0 : attempts - 1;
    // Doubled in milliseconds rather than by multiplying Durations, and clamped before the shift can
    // run away: 2^30 seconds is longer than the app will ever run.
    final grown = doublings >= 30
        ? ceiling
        : Duration(milliseconds: first.inMilliseconds << doublings);
    final capped = grown > ceiling ? ceiling : grown;
    final jittered = _jitter(capped, random ?? Random());
    final asked = retryAfter == null
        ? Duration.zero
        : (retryAfter > longestRetryAfter ? longestRetryAfter : retryAfter);
    return jittered > asked ? jittered : asked;
  }

  /// Whether a task that has failed [attempts] times has any attempt left.
  bool hasAttemptsLeft(int attempts) => attempts < maxAttempts;

  /// [delay], less a random slice of up to half of it.
  ///
  /// Partial rather than full jitter: a retry is never immediate, which matters because an immediate
  /// retry of a connection that just dropped is the one least likely to work and the most likely to
  /// look like hammering. Half is enough spread to keep a hundred installs that failed together from
  /// returning together.
  Duration _jitter(Duration delay, Random random) {
    final half = delay.inMilliseconds ~/ 2;
    if (half <= 0) return delay;
    return Duration(milliseconds: delay.inMilliseconds - random.nextInt(half));
  }
}
