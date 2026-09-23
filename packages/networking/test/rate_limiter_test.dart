import 'dart:async';

import 'package:kikuyomi_networking/kikuyomi_networking.dart';
import 'package:test/test.dart';

/// A clock a test moves by hand, and a wait that moves it rather than sleeping, so that the
/// limiter's arithmetic is checked without any real time passing.
final class _FakeTime {
  var now = DateTime.utc(2025, 1, 1);
  final waits = <Duration>[];

  DateTime read() => now;

  Future<void> wait(Duration duration) async {
    waits.add(duration);
    now = now.add(duration);
  }
}

void main() {
  late _FakeTime time;

  setUp(() => time = _FakeTime());

  RateLimiter limiter({int burst = 4, int maxConcurrent = 4}) => RateLimiter(
    minimumInterval: const Duration(milliseconds: 250),
    burst: burst,
    maxConcurrent: maxConcurrent,
    now: time.read,
    wait: time.wait,
  );

  /// Runs [count] requests one after another and returns how long each waited first.
  Future<List<Duration>> runInTurn(RateLimiter rates, int count) async {
    final waited = <Duration>[];
    for (var i = 0; i < count; i++) {
      final mark = time.waits.length;
      await rates.run(() async {});
      waited.add(time.waits.length > mark ? time.waits[mark] : Duration.zero);
    }
    return waited;
  }

  test('a burst of requests to an idle host is not held back', () async {
    expect(await runInTurn(limiter(), 4), everyElement(Duration.zero));
  });

  test('past the burst, requests settle to the sustained rate', () async {
    final waited = await runInTurn(limiter(), 7);
    expect(waited.take(4), everyElement(Duration.zero));
    expect(
      waited.skip(4),
      everyElement(const Duration(milliseconds: 250)),
      reason: 'the allowance is spent, so each refill is waited for',
    );
  });

  test('a burst of one is a flat gap between every pair', () async {
    final waited = await runInTurn(limiter(burst: 1), 3);
    expect(waited.first, Duration.zero);
    expect(waited.skip(1), everyElement(const Duration(milliseconds: 250)));
  });

  test('time spent idle refills the allowance', () async {
    final rates = limiter();
    await runInTurn(rates, 4);
    // Four intervals of quiet is more than the allowance is worth, so it is full again.
    time.now = time.now.add(const Duration(seconds: 5));
    expect(await runInTurn(rates, 4), everyElement(Duration.zero));
  });

  test('the allowance never refills past the burst', () async {
    final rates = limiter();
    time.now = time.now.add(const Duration(minutes: 10));
    final waited = await runInTurn(rates, 6);
    expect(waited.take(4), everyElement(Duration.zero));
    expect(waited.skip(4), everyElement(const Duration(milliseconds: 250)));
  });

  test('no more than maxConcurrent run at once', () async {
    final rates = limiter(maxConcurrent: 2);
    var running = 0;
    var mostAtOnce = 0;
    final held = <Future<void>>[];
    final gate = <Future<void> Function()>[];
    for (var i = 0; i < 4; i++) {
      final done = Completer<void>();
      gate.add(() async {
        done.complete();
      });
      held.add(
        rates.run(() async {
          running++;
          mostAtOnce = running > mostAtOnce ? running : mostAtOnce;
          await done.future;
          running--;
        }),
      );
    }
    for (final open in gate) {
      await open();
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait(held);
    expect(mostAtOnce, 2);
  });
}
