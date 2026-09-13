import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

const s = 1000;

ChapterPosition at(int chapterId, int offsetMs) =>
    ChapterPosition(chapterId: chapterId, offsetMs: offsetMs);

QueuePosition q(int itemIndex, int offsetMs) =>
    QueuePosition(itemIndex: itemIndex, offsetMs: offsetMs);

/// Two chapters of 300 s in one 600 s file, so the queue is a single item.
Timeline oneFileBook() => Timeline.build(
  files: const [TimelineFile(id: 1, durationMs: 600 * s)],
  chapters: [
    TimelineChapter(
      id: 1,
      title: 'One',
      segments: const [TimelineSegment(fileId: 1, endMs: 300 * s)],
    ),
    TimelineChapter(
      id: 2,
      title: 'Two',
      segments: const [TimelineSegment(fileId: 1, startMs: 300 * s)],
    ),
  ],
);

void main() {
  late FakeClock clock;
  late ProgressTracker tracker;

  setUp(() {
    clock = FakeClock();
    tracker = ProgressTracker(timeline: oneFileBook(), clock: clock);
  });

  group('throttling during playback', () {
    test('the first sample is written, so a started book shows up at once', () {
      expect(tracker.onPosition(q(0, 1 * s)), at(1, 1 * s));
    });

    test('samples inside the throttle window are not written', () {
      tracker.onPosition(q(0, 1 * s));
      clock.advance(const Duration(seconds: 4));
      expect(tracker.onPosition(q(0, 5 * s)), isNull);
      expect(tracker.lastObserved, at(1, 5 * s));
    });

    test('the first sample after the window is written', () {
      tracker.onPosition(q(0, 1 * s));
      clock.advance(const Duration(seconds: 5));
      expect(tracker.onPosition(q(0, 6 * s)), at(1, 6 * s));
    });

    test('a chapter change is written immediately, whatever the throttle', () {
      tracker.onPosition(q(0, 299 * s));
      clock.advance(const Duration(seconds: 1));
      expect(tracker.onPosition(q(0, 300 * s + 500)), at(2, 500));
    });
  });

  group('immediate writes', () {
    test('pause writes the last observed position inside the window', () {
      tracker.onPosition(q(0, 1 * s));
      clock.advance(const Duration(seconds: 1));
      tracker.onPosition(q(0, 2 * s));
      expect(tracker.onPause(), at(1, 2 * s));
    });

    test('interruption and backgrounding write exactly as pause does', () {
      tracker.onPosition(q(0, 1 * s));
      clock.advance(const Duration(seconds: 1));
      tracker.onPosition(q(0, 2 * s));
      expect(tracker.onInterruption(), at(1, 2 * s));

      clock.advance(const Duration(seconds: 1));
      tracker.onPosition(q(0, 3 * s));
      expect(tracker.onBackgrounded(), at(1, 3 * s));
    });

    test('a seek is written at its destination', () {
      expect(tracker.onSeek(q(0, 450 * s)), at(2, 150 * s));
    });

    test('the same position is never written twice in a row', () {
      tracker.onPosition(q(0, 1 * s));
      expect(tracker.onPause(), isNull);
      expect(tracker.onBackgrounded(), isNull);
    });

    test('with nothing observed, there is nothing to write', () {
      expect(tracker.onPause(), isNull);
    });

    test('loading at a position does not write it', () {
      tracker.onLoaded(q(0, 100 * s));
      expect(tracker.lastObserved, at(1, 100 * s));
    });
  });

  group('completion (spike b)', () {
    test('writes the end of the book, not the last sample', () {
      // Spike (b) measured playback stopping a few hundred milliseconds short of nominal duration.
      tracker.onPosition(q(0, 599 * s + 730));
      clock.advance(const Duration(seconds: 1));
      expect(tracker.onCompleted(), at(2, 300 * s));
    });

    test('ignores the position reset to zero that follows completion', () {
      tracker.onPosition(q(0, 599 * s + 730));
      tracker.onCompleted();

      // What the obvious store would have written: the start of the book.
      final timeline = oneFileBook();
      expect(timeline.chapterPositionOfQueue(q(0, 0)), at(1, 0));

      clock.advance(const Duration(seconds: 10));
      expect(tracker.onPosition(q(0, 0)), isNull);
      expect(tracker.lastObserved, at(2, 300 * s));
      expect(tracker.onPause(), isNull);
    });

    test('is written once however often the engine reports it', () {
      expect(tracker.onCompleted(), isNotNull);
      expect(tracker.onCompleted(), isNull);
    });

    test('a seek afterwards starts tracking again', () {
      tracker.onCompleted();
      expect(tracker.onSeek(q(0, 1 * s)), at(1, 1 * s));
      expect(tracker.onPosition(q(0, 2 * s)), isNull);
      clock.advance(const Duration(seconds: 5));
      expect(tracker.onPosition(q(0, 7 * s)), at(1, 7 * s));
    });

    test('a new load afterwards starts tracking again', () {
      tracker.onCompleted();
      tracker.onLoaded(q(0, 10 * s));
      expect(tracker.onPosition(q(0, 11 * s)), at(1, 11 * s));
    });
  });

  test('tracked progress survives a duration refinement', () {
    Timeline book({required int firstFileMs, bool estimate = false}) =>
        Timeline.build(
          files: [
            TimelineFile(
              id: 1,
              durationMs: firstFileMs,
              durationIsEstimate: estimate,
            ),
            const TimelineFile(id: 2, durationMs: 300 * s),
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

    tracker = ProgressTracker(
      timeline: book(firstFileMs: 300 * s, estimate: true),
      clock: clock,
    );
    tracker.onPosition(q(1, 1 * s));
    clock.advance(const Duration(seconds: 1));
    tracker.onPosition(q(1, 2 * s));

    tracker.updateTimeline(book(firstFileMs: 312 * s));

    expect(tracker.onPause(), at(2, 2 * s));
    clock.advance(const Duration(seconds: 5));
    expect(tracker.onPosition(q(1, 9 * s)), at(2, 9 * s));
  });
}
