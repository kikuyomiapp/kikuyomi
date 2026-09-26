// How fast a download is moving, from the reports as they arrive.
//
// The arithmetic is small and every interesting case is a degenerate one: two reports in the same
// millisecond, bytes that go backwards because a task restarted, a task that stopped reporting and
// whose last speed is no longer true. Each of those turns into either a wrong number on screen or a
// division that should never have happened.

import 'package:kikuyomi_downloads/kikuyomi_downloads.dart';
import 'package:test/test.dart';

final _start = DateTime.utc(2026, 9, 25, 9);

DateTime at(int seconds) => _start.add(Duration(seconds: seconds));

void main() {
  late DownloadRates rates;

  setUp(() => rates = DownloadRates());

  group('measuring', () {
    test('needs two reports before it says anything', () {
      rates.sample(1, bytesDone: 0, at: at(0));

      expect(rates.bytesPerSecond(1, at(0)), isNull);
    });

    test('is bytes over the time between them', () {
      rates.sample(1, bytesDone: 0, at: at(0));
      rates.sample(1, bytesDone: 2000, at: at(2));

      expect(rates.bytesPerSecond(1, at(2)), 1000);
    });

    test('measures across the whole window, not the last pair', () {
      // A single slow report in the middle of a fast download should not drag the figure down to
      // whatever happened in the last three hundred milliseconds.
      for (var second = 0; second <= 4; second++) {
        rates.sample(1, bytesDone: second * 1000, at: at(second));
      }

      expect(rates.bytesPerSecond(1, at(4)), 1000);
    });

    test('a task nobody has reported on has no speed', () {
      expect(rates.bytesPerSecond(404, at(0)), isNull);
    });
  });

  group('the degenerate cases', () {
    test('two reports in the same instant say nothing', () {
      rates.sample(1, bytesDone: 0, at: at(0));
      rates.sample(1, bytesDone: 5000, at: at(0));

      expect(
        rates.bytesPerSecond(1, at(0)),
        isNull,
        reason: 'dividing by no time at all says something absurd',
      );
    });

    test('bytes going backwards start the measurement again', () {
      // A restarted task, or one that reported nought because the site had not said how big the file
      // was. What came before describes a different download.
      rates.sample(1, bytesDone: 9000, at: at(0));
      rates.sample(1, bytesDone: 0, at: at(1));

      expect(rates.bytesPerSecond(1, at(1)), isNull);

      rates.sample(1, bytesDone: 1000, at: at(3));
      expect(rates.bytesPerSecond(1, at(3)), 500);
    });

    test('a task that stopped reporting stops having a speed', () {
      // Paused, wedged, or finished. The last speed it was moving at is no longer true, and showing
      // it would be a download that looks alive.
      rates.sample(1, bytesDone: 0, at: at(0));
      rates.sample(1, bytesDone: 2000, at: at(2));

      expect(rates.bytesPerSecond(1, at(4)), 1000);
      expect(rates.bytesPerSecond(1, at(30)), isNull);
    });

    test('a download that has stalled reads as nought, not as nothing', () {
      // Distinct from the case above: it is still reporting, it is just not moving. Nought is the
      // true answer and the listener should see it.
      rates.sample(1, bytesDone: 5000, at: at(0));
      rates.sample(1, bytesDone: 5000, at: at(2));

      expect(rates.bytesPerSecond(1, at(2)), 0);
    });
  });

  group('the window', () {
    test('forgets what happened before it', () {
      final slow = DownloadRates(window: Duration(seconds: 4));
      // A fast start, then a long slow stretch. Once the fast part is out of the window the figure
      // should describe the slow part alone.
      slow.sample(1, bytesDone: 0, at: at(0));
      slow.sample(1, bytesDone: 100000, at: at(1));
      for (var second = 2; second <= 10; second++) {
        slow.sample(1, bytesDone: 100000 + (second - 1) * 100, at: at(second));
      }

      expect(slow.bytesPerSecond(1, at(10)), closeTo(100, 1));
    });

    test('keeps enough to measure a steady download', () {
      // The far end of the window is what the newest sample is compared against, so it has to be
      // kept rather than dropped the moment it ages out.
      final rates = DownloadRates(window: Duration(seconds: 5));
      for (var second = 0; second <= 20; second++) {
        rates.sample(1, bytesDone: second * 1000, at: at(second));
      }

      expect(rates.bytesPerSecond(1, at(20)), closeTo(1000, 1));
    });
  });

  group('a book at a time', () {
    test('adds up what its files are doing', () {
      rates.sample(1, bytesDone: 0, at: at(0));
      rates.sample(1, bytesDone: 2000, at: at(2));
      rates.sample(2, bytesDone: 0, at: at(0));
      rates.sample(2, bytesDone: 6000, at: at(2));

      expect(rates.totalBytesPerSecond([1, 2], at(2)), 4000);
    });

    test('ignores the ones that cannot say', () {
      rates.sample(1, bytesDone: 0, at: at(0));
      rates.sample(1, bytesDone: 2000, at: at(2));
      rates.sample(2, bytesDone: 0, at: at(0));

      expect(rates.totalBytesPerSecond([1, 2, 404], at(2)), 1000);
    });

    test('is nothing when none of them can', () {
      expect(rates.totalBytesPerSecond([1, 2], at(2)), isNull);
    });
  });

  group('forgetting', () {
    test('one task', () {
      rates.sample(1, bytesDone: 0, at: at(0));
      rates.sample(1, bytesDone: 2000, at: at(2));

      rates.forget(1);

      expect(rates.bytesPerSecond(1, at(2)), isNull);
    });

    test('and all of them', () {
      rates.sample(1, bytesDone: 0, at: at(0));
      rates.sample(1, bytesDone: 2000, at: at(2));

      rates.clear();

      expect(rates.bytesPerSecond(1, at(2)), isNull);
    });

    test('forgetting one that was never there is not a failure', () {
      expect(() => rates.forget(404), returnsNormally);
    });
  });
}
