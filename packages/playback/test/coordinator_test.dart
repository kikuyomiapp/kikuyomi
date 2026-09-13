import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

const s = 1000;

Duration sec(int n) => Duration(seconds: n);

ChapterPosition at(int chapterId, int offsetMs) =>
    ChapterPosition(chapterId: chapterId, offsetMs: offsetMs);

QueuePosition q(int item, int offsetMs) =>
    QueuePosition(itemIndex: item, offsetMs: offsetMs);

/// Two chapters, one 300 s file each.
Timeline twoFileBook() => Timeline.build(
  files: const [
    TimelineFile(id: 1, durationMs: 300 * s),
    TimelineFile(id: 2, durationMs: 300 * s),
  ],
  chapters: [
    TimelineChapter(
      id: 1,
      title: 'One',
      segments: const [TimelineSegment(fileId: 1)],
    ),
    TimelineChapter(
      id: 2,
      title: 'Two',
      segments: const [TimelineSegment(fileId: 2)],
    ),
  ],
);

void main() {
  late FakeClock clock;
  late FakeEngine engine;
  late FakeResolver resolver;
  late FakeStore store;
  late PlaybackCoordinator coordinator;

  setUp(() {
    clock = FakeClock();
    engine = FakeEngine();
    resolver = FakeResolver();
    store = FakeStore();
    coordinator = PlaybackCoordinator(
      engine: engine,
      resolver: resolver,
      store: store,
      clock: clock,
    );
  });

  tearDown(() => coordinator.close());

  Future<void> openBook({
    int bookId = 1,
    ChapterPosition? resumeFrom,
    Duration pausedFor = Duration.zero,
  }) => coordinator.open(
    PlaybackRequest(
      bookId: bookId,
      timeline: twoFileBook(),
      resumeFrom: resumeFrom,
      pausedFor: pausedFor,
    ),
  );

  /// Emits an engine event and lets the coordinator's queue drain.
  Future<void> emit(EngineEvent event) async {
    engine.emit(event);
    await pumpEventQueue();
  }

  PlayerReady ready() {
    expect(coordinator.state, isA<PlayerReady>());
    return coordinator.state as PlayerReady;
  }

  group('opening a book', () {
    test(
      'resolves every file and loads at the start, without playing',
      () async {
        await openBook();
        expect(engine.loaded.map((e) => e.media.uri.path), [
          '/books/1.m4a',
          '/books/2.m4a',
        ]);
        expect(engine.loadedAt, q(0, 0));
        expect(engine.calls, isNot(contains('play')));
        expect(ready().position, at(1, 0));
        expect(store.progress, isEmpty, reason: 'loading is not listening');
      },
    );

    test(
      'resumes a saved position with smart rewind applied, via load',
      () async {
        // Loading at the position rather than seeking to it is spike (b)'s rule: a combined seek
        // into another item drops the offset.
        await openBook(
          resumeFrom: at(2, 60 * s),
          pausedFor: const Duration(hours: 3),
        );
        expect(engine.loadedAt, q(1, 30 * s));
        expect(engine.calls, isNot(contains('seek')));
      },
    );

    test('reports a file that cannot be resolved', () async {
      resolver.failing.add(2);
      await openBook();
      expect(coordinator.state, isA<PlayerFailed>());
    });

    test('opening another book saves the first before leaving it', () async {
      await openBook(bookId: 1);
      await coordinator.play();
      clock.advance(sec(10));
      await emit(EnginePositionChanged(q(0, 10 * s)));

      await openBook(bookId: 2);

      expect(
        engine.calls.lastIndexOf('pause'),
        lessThan(engine.calls.lastIndexOf('load')),
      );
      expect(store.sessions.single.bookId, 1);
      expect(store.progress.last.bookId, 1);
      expect(ready().bookId, 2);
    });
  });

  group('playing and progress', () {
    test(
      'play and pause drive the engine and save progress and listening',
      () async {
        await openBook();
        await coordinator.play();
        expect(ready().playing, isTrue);

        clock.advance(sec(10));
        await emit(EnginePositionChanged(q(0, 10 * s)));
        await coordinator.pause();

        expect(engine.playing, isFalse);
        expect(ready().playing, isFalse);
        expect(store.progress.last.position, at(1, 10 * s));
        expect(store.sessions.single.listened, sec(10));
      },
    );

    test('progress writes are throttled during playback', () async {
      await openBook();
      await coordinator.play();
      for (var i = 1; i <= 12; i++) {
        clock.advance(sec(1));
        await emit(EnginePositionChanged(q(0, i * s)));
      }
      expect(
        [for (final p in store.progress) p.position.offsetMs],
        [1 * s, 6 * s, 11 * s],
      );
    });

    test(
      'the global position is saved alongside the chapter position',
      () async {
        await openBook();
        await coordinator.play();
        await emit(EnginePositionChanged(q(1, 5 * s)));
        expect(store.progress.last.position, at(2, 5 * s));
        expect(store.progress.last.globalMs, 305 * s);
      },
    );
  });

  group('completion (spike b)', () {
    test(
      'saves the end of the book and ignores the zero reported afterwards',
      () async {
        await openBook();
        await coordinator.play();
        await emit(EnginePositionChanged(q(1, 299 * s)));
        await emit(const EngineCompleted());
        await emit(EnginePositionChanged(q(0, 0)));

        expect(store.progress.last.position, at(2, 300 * s));
        final state = ready();
        expect(state.finished, isTrue);
        expect(state.playing, isFalse);
        expect(
          state.globalMs,
          600 * s,
          reason: 'the displayed position must not reset',
        );
      },
    );

    test('playing a finished book starts it again', () async {
      await openBook();
      await coordinator.play();
      await emit(const EngineCompleted());
      await coordinator.play();
      expect(engine.lastSeek, q(0, 0));
      expect(ready().finished, isFalse);
    });
  });

  group('navigation', () {
    test('seeking saves the destination immediately', () async {
      await openBook();
      await coordinator.seekTo(400 * s);
      expect(engine.lastSeek, q(1, 100 * s));
      expect(store.progress.last.position, at(2, 100 * s));
    });

    test('skipping back is clamped to the start of the book', () async {
      await openBook();
      await coordinator.seekTo(10 * s);
      await coordinator.skip(sec(-30));
      expect(engine.lastSeek, q(0, 0));
    });

    test('next chapter moves to the start of the next one', () async {
      await openBook();
      await coordinator.seekTo(100 * s);
      await coordinator.nextChapter();
      expect(engine.lastSeek, q(1, 0));
    });

    test('next chapter in the last chapter does nothing', () async {
      await openBook();
      await coordinator.seekTo(400 * s);
      engine.calls.clear();
      await coordinator.nextChapter();
      expect(engine.calls, isEmpty);
    });

    test('previous chapter well into a chapter restarts it', () async {
      await openBook();
      await coordinator.seekTo(310 * s);
      await coordinator.previousChapter();
      expect(engine.lastSeek, q(1, 0));
    });

    test(
      'previous chapter near the start goes to the previous chapter',
      () async {
        await openBook();
        await coordinator.seekTo(302 * s);
        await coordinator.previousChapter();
        expect(engine.lastSeek, q(0, 0));
      },
    );
  });

  group('speed', () {
    test('is applied, remembered for the book, and splits listening', () async {
      await openBook();
      await coordinator.play();
      clock.advance(sec(20));
      await emit(EnginePositionChanged(q(0, 20 * s)));
      await coordinator.setSpeed(1.5);

      expect(engine.speed, 1.5);
      expect(store.speeds.single, (bookId: 1, speed: 1.5));
      expect(store.sessions.single.speed, 1.0);
      expect(ready().speed, 1.5);
    });

    test('outside 0.5x to 3.5x is rejected', () async {
      await openBook();
      expect(coordinator.setSpeed(4.0), throwsArgumentError);
      expect(coordinator.setSpeed(0.25), throwsArgumentError);
    });
  });

  group('resuming after a pause', () {
    test('applies smart rewind for the length of the pause', () async {
      await openBook();
      await coordinator.play();
      clock.advance(sec(60));
      await emit(EnginePositionChanged(q(0, 60 * s)));
      await coordinator.pause();

      clock.advance(const Duration(minutes: 10));
      await coordinator.play();

      expect(engine.lastSeek, q(0, 50 * s));
      expect(engine.playing, isTrue);
    });

    test('does not rewind after a brief pause', () async {
      await openBook();
      await coordinator.play();
      clock.advance(sec(60));
      await emit(EnginePositionChanged(q(0, 60 * s)));
      await coordinator.pause();
      engine.calls.clear();
      clock.advance(sec(2));
      await coordinator.play();
      expect(engine.calls, isNot(contains('seek')));
    });
  });

  group('sleep timer', () {
    test('fades the volume and pauses when it runs out', () async {
      await openBook();
      await coordinator.startSleepTimer(SleepAfter(sec(60)));
      await coordinator.play();

      clock.advance(sec(50));
      await emit(EnginePositionChanged(q(0, 50 * s)));
      expect(engine.volume, 0.5);

      clock.advance(sec(10));
      await emit(EnginePositionChanged(q(0, 60 * s)));
      expect(engine.playing, isFalse);
      expect(
        engine.volume,
        1.0,
        reason: 'the volume is restored for next time',
      );
      expect(ready().playing, isFalse);
    });

    test('rewinds by the fade on the next play', () async {
      await openBook();
      await coordinator.startSleepTimer(SleepAfter(sec(60)));
      await coordinator.play();
      clock.advance(sec(60));
      await emit(EnginePositionChanged(q(0, 60 * s)));

      await coordinator.play();
      expect(engine.lastSeek, q(0, 40 * s));
    });

    test('is reported in the player state', () async {
      await openBook();
      await coordinator.startSleepTimer(SleepAfter(sec(90)));
      final timer = ready().sleepTimer;
      expect(timer, isA<SleepTimerRunning>());
      expect((timer as SleepTimerRunning).remaining, sec(90));
    });

    test('cancelling it restores the volume', () async {
      await openBook();
      await coordinator.startSleepTimer(SleepAfter(sec(60)));
      await coordinator.play();
      clock.advance(sec(50));
      await emit(EnginePositionChanged(q(0, 50 * s)));
      await coordinator.cancelSleepTimer();
      expect(engine.volume, 1.0);
      expect(ready().sleepTimer, isA<SleepTimerOff>());
    });
  });

  group('stream errors (§6.3)', () {
    test(
      'are recovered once by re-resolving and reloading where playback was',
      () async {
        await openBook();
        await coordinator.play();
        await emit(EnginePositionChanged(q(1, 5 * s)));
        resolver.requests.clear();
        engine.calls.clear();

        await emit(EngineFailed(StateError('403')));

        expect(resolver.requests, everyElement((r) => r.refresh == true));
        expect(engine.calls, ['load', 'play']);
        expect(engine.loadedAt, q(1, 5 * s));
        expect(ready().playing, isTrue);
      },
    );

    test('a second failure before any user action is surfaced', () async {
      await openBook();
      await coordinator.play();
      await emit(EngineFailed(StateError('403')));
      await emit(EngineFailed(StateError('403 again')));
      expect(coordinator.state, isA<PlayerFailed>());
    });

    test('a user action re-arms recovery', () async {
      await openBook();
      await coordinator.play();
      await emit(EngineFailed(StateError('403')));
      await coordinator.seekTo(20 * s);
      await emit(EngineFailed(StateError('403 later')));
      expect(coordinator.state, isA<PlayerReady>());
    });

    test('recovery that cannot resolve is surfaced', () async {
      await openBook();
      await coordinator.play();
      resolver.failing.add(1);
      await emit(EngineFailed(StateError('403')));
      expect(coordinator.state, isA<PlayerFailed>());
    });
  });

  test('backgrounding saves progress without pausing', () async {
    await openBook();
    await coordinator.play();
    await emit(EnginePositionChanged(q(0, 1 * s)));
    clock.advance(sec(2));
    await emit(EnginePositionChanged(q(0, 3 * s)));
    await coordinator.onBackgrounded();
    expect(store.progress.last.position, at(1, 3 * s));
    expect(engine.playing, isTrue);
  });
}
