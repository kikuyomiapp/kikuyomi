import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

Duration sec(int n) => Duration(seconds: n);
Duration min(int n) => Duration(minutes: n);

SleepTimerRunning running(SleepTimerState state) {
  expect(state, isA<SleepTimerRunning>());
  return state as SleepTimerRunning;
}

void main() {
  late FakeClock clock;
  late SleepTimer timer;

  setUp(() {
    clock = FakeClock();
    timer = SleepTimer(clock: clock);
  });

  test('is off until started', () {
    expect(timer.poll(), isA<SleepTimerOff>());
    expect(timer.isActive, isFalse);
  });

  group('a duration timer', () {
    test('counts down while playing', () {
      timer.start(SleepAfter(min(10)));
      timer.onPlaying();
      clock.advance(min(5));
      final state = running(timer.poll());
      expect(state.remaining, min(5));
      expect(state.volume, 1.0);
    });

    test('stands still while paused', () {
      timer.start(SleepAfter(min(10)));
      timer.onPlaying();
      clock.advance(min(2));
      timer.onPaused();
      clock.advance(const Duration(hours: 1));
      timer.onPlaying();
      clock.advance(min(1));
      expect(running(timer.poll()).remaining, min(7));
    });

    test('started during playback counts from when it was set', () {
      timer.onPlaying();
      clock.advance(const Duration(hours: 1));
      timer.start(SleepAfter(min(10)));
      clock.advance(min(1));
      expect(running(timer.poll()).remaining, min(9));
    });

    test('fades linearly over the final fade window', () {
      timer.start(SleepAfter(sec(60)));
      timer.onPlaying();
      clock.advance(sec(50));
      final state = running(timer.poll());
      expect(state.remaining, sec(10));
      expect(state.volume, 0.5);
    });

    test('expires exactly once, then is off', () {
      timer.start(SleepAfter(sec(60)));
      timer.onPlaying();
      clock.advance(sec(60));
      expect(timer.poll(), isA<SleepTimerExpired>());
      expect(timer.poll(), isA<SleepTimerOff>());
      expect(timer.isActive, isFalse);
    });

    test('starting another timer replaces it', () {
      timer.start(SleepAfter(min(10)));
      timer.onPlaying();
      clock.advance(min(1));
      timer.start(SleepAfter(min(30)));
      expect(running(timer.poll()).remaining, min(30));
    });
  });

  group('an end-of-chapter timer', () {
    setUp(() => timer.start(const SleepAtEndOfChapter()));

    test('measures what is left of the chapter', () {
      final state = running(timer.poll(chapterRemaining: sec(40)));
      expect(state.remaining, sec(40));
      expect(state.volume, 1.0);
    });

    test('fades as the chapter end approaches', () {
      expect(running(timer.poll(chapterRemaining: sec(10))).volume, 0.5);
    });

    test('expires at the end of the chapter', () {
      expect(
        timer.poll(chapterRemaining: Duration.zero),
        isA<SleepTimerExpired>(),
      );
    });

    test('measures in listening time, so speed brings the fade forward', () {
      final state = running(timer.poll(chapterRemaining: sec(30), speed: 2));
      expect(state.remaining, sec(15));
      expect(state.volume, 0.75);
    });

    test('needs to know how much of the chapter is left', () {
      expect(() => timer.poll(), throwsArgumentError);
    });

    test('cannot be extended, having no length to add to', () {
      expect(() => timer.extend(min(5)), throwsStateError);
    });
  });

  group('extending (shake-to-extend)', () {
    test('adds time and lifts the fade', () {
      timer.start(SleepAfter(sec(60)));
      timer.onPlaying();
      clock.advance(sec(50));
      timer.extend(min(5));
      final state = running(timer.poll());
      expect(state.remaining, min(5) + sec(10));
      expect(state.volume, 1.0);
    });

    test('needs a running timer', () {
      expect(() => timer.extend(min(5)), throwsStateError);
    });

    test('rejects a negative extension', () {
      timer.start(SleepAfter(min(10)));
      expect(() => timer.extend(sec(-1)), throwsArgumentError);
    });
  });

  group('the rewind on resume (§6.5)', () {
    test('is the fade length after the timer stopped playback, once', () {
      timer.start(SleepAfter(sec(60)));
      timer.onPlaying();
      clock.advance(sec(60));
      timer.poll();
      expect(timer.takeResumeRewind(), sec(20));
      expect(timer.takeResumeRewind(), Duration.zero);
    });

    test('is zero when the timer was cancelled before it ran out', () {
      timer.start(SleepAfter(sec(60)));
      timer.onPlaying();
      clock.advance(sec(30));
      timer.cancel();
      expect(timer.poll(), isA<SleepTimerOff>());
      expect(timer.takeResumeRewind(), Duration.zero);
    });
  });

  test('the fade must be within the 15 to 30 seconds §6.5 allows', () {
    expect(() => SleepTimer(clock: clock, fade: sec(14)), throwsArgumentError);
    expect(() => SleepTimer(clock: clock, fade: sec(31)), throwsArgumentError);
    expect(SleepTimer(clock: clock, fade: sec(15)).fade, sec(15));
    expect(SleepTimer(clock: clock, fade: sec(30)).fade, sec(30));
  });

  test('a non-positive speed is rejected', () {
    timer.start(const SleepAtEndOfChapter());
    expect(
      () => timer.poll(chapterRemaining: sec(10), speed: 0),
      throwsArgumentError,
    );
  });
}
