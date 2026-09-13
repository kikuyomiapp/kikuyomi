// A Timeline is built from stored data. These pin down that inconsistent data fails loudly at
// build time, instead of producing positions that are quietly wrong during playback.

import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Matcher throwsInvalid(String fragment) => throwsA(
  isA<InvalidTimelineException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  const file = TimelineFile(id: 1, durationMs: 100 * s);

  test('a book needs at least one chapter', () {
    expect(
      () => Timeline.build(files: const [file], chapters: const []),
      throwsInvalid('at least one chapter'),
    );
  });

  test('a chapter needs at least one segment', () {
    expect(
      () => Timeline.build(
        files: const [file],
        chapters: [TimelineChapter(id: 1, title: 'x', segments: const [])],
      ),
      throwsInvalid('no segments'),
    );
  });

  test('a segment must refer to a known file', () {
    expect(
      () => Timeline.build(
        files: const [file],
        chapters: [
          chapter(1, [seg(99)]),
        ],
      ),
      throwsInvalid('unknown file 99'),
    );
  });

  test('a segment cannot end beyond its file', () {
    expect(
      () => Timeline.build(
        files: const [file],
        chapters: [
          chapter(1, [seg(1, 0, 101 * s)]),
        ],
      ),
      throwsInvalid('beyond'),
    );
  });

  test('a segment cannot start before its file', () {
    expect(
      () => Timeline.build(
        files: const [file],
        chapters: [
          chapter(1, [seg(1, -1, 10 * s)]),
        ],
      ),
      throwsInvalid('starting before'),
    );
  });

  test('a segment cannot be empty', () {
    expect(
      () => Timeline.build(
        files: const [file],
        chapters: [
          chapter(1, [seg(1, 50 * s, 50 * s)]),
        ],
      ),
      throwsInvalid('empty segment'),
    );
  });

  test('a file of unknown, zero duration cannot back a whole-file segment', () {
    // The data layer must supply an estimate instead; this is what happens if it does not.
    expect(
      () => Timeline.build(
        files: const [TimelineFile(id: 1, durationMs: 0)],
        chapters: [
          chapter(1, [seg(1)]),
        ],
      ),
      throwsInvalid('empty segment'),
    );
  });

  test('chapter and file ids must be unique', () {
    expect(
      () => Timeline.build(
        files: const [file],
        chapters: [
          chapter(1, [seg(1, 0, 10 * s)]),
          chapter(1, [seg(1, 10 * s)]),
        ],
      ),
      throwsInvalid('chapter 1 appears twice'),
    );
    expect(
      () => Timeline.build(
        files: const [file, file],
        chapters: [
          chapter(1, [seg(1)]),
        ],
      ),
      throwsInvalid('file 1 appears twice'),
    );
  });

  test('a duration cannot be negative', () {
    expect(
      () => Timeline.build(
        files: const [TimelineFile(id: 1, durationMs: -1)],
        chapters: [
          chapter(1, [seg(1)]),
        ],
      ),
      throwsInvalid('negative duration'),
    );
  });

  test('looking up a chapter from another book is an argument error', () {
    expect(() => diagramBook().chapterDurationMs(42), throwsArgumentError);
  });

  test('an engine position outside the queue is a range error', () {
    final t = diagramBook();
    expect(
      () => t.globalOfQueue(const QueuePosition(itemIndex: 3, offsetMs: 0)),
      throwsRangeError,
    );
    expect(
      () => t.fileOffsetOf(const QueuePosition(itemIndex: -1, offsetMs: 0)),
      throwsRangeError,
    );
  });

  test(
    'inputs are copied, so later mutation cannot change a built Timeline',
    () {
      final segments = [seg(1)];
      final t = Timeline.build(
        files: const [file],
        chapters: [TimelineChapter(id: 1, title: 'x', segments: segments)],
      );
      segments.add(seg(1));
      expect(t.totalDurationMs, 100 * s);
      expect(() => t.queue.add(t.queue.first), throwsUnsupportedError);
    },
  );
}
