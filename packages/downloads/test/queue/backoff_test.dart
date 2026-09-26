// §5.5's retry schedule: exponential, jittered, respecting Retry-After, and giving up after five.

import 'dart:math';

import 'package:kikuyomi_downloads/kikuyomi_downloads.dart';
import 'package:test/test.dart';

/// A `Random` that always answers the same, so a schedule can be read exactly.
final class _Fixed implements Random {
  const _Fixed(this.value);

  /// What [nextInt] gives, held below its bound.
  final int value;

  @override
  int nextInt(int max) => value >= max ? max - 1 : value;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

/// No jitter at all: the schedule's own figure, undisturbed.
const plain = _Fixed(0);

/// As much jitter as the schedule allows, which is half.
const jittery = _Fixed(1 << 30);

void main() {
  const backoff = DownloadBackoff();

  group('the schedule', () {
    test('doubles with each failure', () {
      expect(backoff.after(1, random: plain), const Duration(seconds: 5));
      expect(backoff.after(2, random: plain), const Duration(seconds: 10));
      expect(backoff.after(3, random: plain), const Duration(seconds: 20));
      expect(backoff.after(4, random: plain), const Duration(seconds: 40));
    });

    test('stops doubling at the ceiling', () {
      const patient = DownloadBackoff(
        ceiling: Duration(seconds: 12),
        maxAttempts: 10,
      );

      expect(patient.after(3, random: plain), const Duration(seconds: 12));
      expect(patient.after(9, random: plain), const Duration(seconds: 12));
    });

    test('gives up after five attempts (§5.5)', () {
      expect(backoff.after(5), isNull);
      expect(backoff.after(6), isNull);
      expect(backoff.hasAttemptsLeft(4), isTrue);
      expect(backoff.hasAttemptsLeft(5), isFalse);
    });

    test('a huge attempt count does not run the shift away', () {
      // Doubling in milliseconds means a big enough count would shift the value into nonsense, so
      // the growth is clamped before the shift rather than after it.
      const forgiving = DownloadBackoff(maxAttempts: 1000);

      expect(forgiving.after(500, random: plain), forgiving.ceiling);
    });
  });

  group('jitter', () {
    test('takes away up to half, and never more', () {
      final full = backoff.after(3, random: jittery)!;

      expect(full, lessThan(const Duration(seconds: 20)));
      expect(full, greaterThanOrEqualTo(const Duration(seconds: 10)));
    });

    test('never makes a retry immediate', () {
      // An immediate retry of a connection that just dropped is the one least likely to work and the
      // most likely to look like hammering.
      for (var attempt = 1; attempt < 5; attempt++) {
        expect(
          backoff.after(attempt, random: jittery),
          greaterThan(Duration.zero),
          reason: 'attempt $attempt',
        );
      }
    });

    test('is real, across many draws', () {
      final seen = {
        for (var i = 0; i < 200; i++) backoff.after(3, random: Random(i)),
      };

      expect(
        seen.length,
        greaterThan(1),
        reason:
            'a hundred installs that failed together must not return together',
      );
    });
  });

  group('what the site asked for', () {
    test('is a floor, not an answer', () {
      // A server saying "wait 60 seconds" on a first failure knows something the schedule does not.
      expect(
        backoff.after(
          1,
          retryAfter: const Duration(seconds: 60),
          random: plain,
        ),
        const Duration(seconds: 60),
      );

      // But one asking for a second on a fourth failure is not a reason to forget what the schedule
      // has learned.
      expect(
        backoff.after(4, retryAfter: const Duration(seconds: 1), random: plain),
        const Duration(seconds: 40),
      );
    });

    test('is honoured only so far', () {
      // Respecting it is the polite thing, but a header asking for a day would strand the queue
      // silently, so past the limit the listener is left to ask again instead.
      expect(
        backoff.after(1, retryAfter: const Duration(days: 1), random: plain),
        const Duration(hours: 1),
      );
    });

    test('does not buy an attempt back', () {
      expect(
        backoff.after(5, retryAfter: const Duration(seconds: 1)),
        isNull,
        reason: 'five attempts is five attempts, whatever the site says',
      );
    });
  });
}
