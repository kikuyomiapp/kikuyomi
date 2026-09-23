/// How often one site may be asked (§3.5, §5.5).
///
/// A scraper that fetches as fast as the device allows gets the listener's address blocked, and a
/// blocked address is worse for them than a slow page. §5.5 asks for "retries and protection
/// against bans"; this is the front half of that: a sustained rate for one host, a burst a caller
/// may spend before that rate is enforced, and a cap on how many requests are in flight at once.
///
/// **Why a burst, and not a flat gap.** A flat minimum gap between requests charges the app for
/// work it does in bursts and then stops: opening a book asks its source about several chapters at
/// once and then nothing for an hour, and a quarter of a second between each of those is a delay
/// the app imposes on itself for no one's benefit. What a site is protecting itself from is a
/// *sustained* flood, so that is what is limited here — the average rate — while a handful of
/// requests may go straight out. Idle time refills the allowance, so a burst is only ever spent by
/// an app that has been quiet.
///
/// Waiting happens inside the limiter, so every caller of the client is held to it without knowing
/// it exists.
library;

import 'dart:async';
import 'dart:collection';

/// A queue that lets requests through no faster than it was told to.
final class RateLimiter {
  RateLimiter({
    this.minimumInterval = const Duration(milliseconds: 250),
    this.burst = 4,
    this.maxConcurrent = 4,
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
  }) : assert(burst >= 1, 'a limiter that lets nothing through is a deadlock'),
       _now = now ?? DateTime.now,
       _wait = wait ?? _sleep;

  static Future<void> _sleep(Duration duration) => Future.delayed(duration);

  /// The sustained time between the starts of two requests to one host.
  ///
  /// Not a hard gap: see [burst]. Over any long enough stretch, requests start no more often than
  /// this on average.
  final Duration minimumInterval;

  /// How many requests a caller that has been idle may start without waiting.
  ///
  /// The allowance refills at one request per [minimumInterval] and never grows past this, so a
  /// limiter that has been quiet for a while lets a burst of this many straight through and then
  /// settles to the sustained rate. One means the old behaviour: a flat gap between every pair.
  final int burst;

  /// How many requests to one host may be in flight at once.
  final int maxConcurrent;

  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;

  final _waiting = Queue<Completer<void>>();

  /// The earliest time at which a request could start if no allowance were left: the "theoretical
  /// arrival time" of the classic leaky bucket. A request may start [_allowance] before it.
  DateTime? _nextIfEmpty;
  var _running = 0;

  /// How far ahead of [_nextIfEmpty] a request may start, which is what the unspent burst is worth.
  Duration get _allowance => minimumInterval * (burst - 1);

  /// Runs [body] when its turn comes, and lets the next one through afterwards.
  Future<T> run<T>(Future<T> Function() body) async {
    await _take();
    try {
      return await body();
    } finally {
      _release();
    }
  }

  Future<void> _take() async {
    if (_running >= maxConcurrent) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    final now = _now();
    final nextIfEmpty = _nextIfEmpty ?? now;
    // The bucket has room now if we are within the allowance of the theoretical arrival time.
    final earliest = nextIfEmpty.subtract(_allowance);
    final start = earliest.isAfter(now) ? earliest : now;
    if (start.isAfter(now)) await _wait(start.difference(now));
    // Time spent idle refills the allowance, and never more than the burst is worth, which is what
    // taking the later of the two does.
    _nextIfEmpty = (nextIfEmpty.isAfter(start) ? nextIfEmpty : start).add(
      minimumInterval,
    );
  }

  void _release() {
    _running--;
    if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
  }
}
