/// How often one site may be asked (§3.5, §5.5).
///
/// A scraper that fetches as fast as the device allows gets the listener's address blocked, and a
/// blocked address is worse for them than a slow page. §5.5 asks for "retries and protection
/// against bans"; this is the front half of that: a minimum gap between requests to one host, and a
/// cap on how many are in flight at once.
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
    this.maxConcurrent = 4,
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
  }) : _now = now ?? DateTime.now,
       _wait = wait ?? _sleep;

  static Future<void> _sleep(Duration duration) => Future.delayed(duration);

  /// The least time between the starts of two requests to one host.
  final Duration minimumInterval;

  /// How many requests to one host may be in flight at once.
  final int maxConcurrent;

  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;

  final _waiting = Queue<Completer<void>>();
  DateTime? _lastStarted;
  var _running = 0;

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
    final last = _lastStarted;
    if (last != null) {
      final since = _now().difference(last);
      if (since < minimumInterval) {
        await _wait(minimumInterval - since);
      }
    }
    _lastStarted = _now();
  }

  void _release() {
    _running--;
    if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
  }
}
