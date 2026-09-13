// The four real-world layouts from docs/architecture.md §1.5. The Timeline must represent all of
// them without special-casing, so each gets the same questions: what does the engine queue look
// like, and do the three coordinate systems agree at the places that matter?

import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('layout 1: one file per chapter', () {
    final t = Timeline.build(
      files: const [
        TimelineFile(id: 10, durationMs: 60 * s),
        TimelineFile(id: 20, durationMs: 90 * s),
        TimelineFile(id: 30, durationMs: 30 * s),
      ],
      chapters: [
        chapter(1, [seg(10)]),
        chapter(2, [seg(20)]),
        chapter(3, [seg(30)]),
      ],
    );

    test('one queue item per file', () {
      expect(t.queue, const [
        QueueItem(fileId: 10, clipStartMs: 0, clipEndMs: 60 * s),
        QueueItem(fileId: 20, clipStartMs: 0, clipEndMs: 90 * s),
        QueueItem(fileId: 30, clipStartMs: 0, clipEndMs: 30 * s),
      ]);
      expect(t.totalDurationMs, 180 * s);
    });

    test('a chapter position maps to the same offset in its own item', () {
      expect(t.globalOf(at(2, 10 * s)), 70 * s);
      expect(t.queuePositionOfChapter(at(2, 10 * s)), item(1, 10 * s));
    });

    test('a chapter boundary belongs to the chapter that begins there', () {
      expect(t.chapterPositionAt(60 * s), at(2, 0));
      expect(t.queuePositionAt(60 * s), item(1, 0));
    });
  });

  group('layout 2: one large file holding every chapter', () {
    final t = Timeline.build(
      files: const [TimelineFile(id: 1, durationMs: 600 * s)],
      chapters: [
        chapter(1, [seg(1, 0, 200 * s)]),
        chapter(2, [seg(1, 200 * s, 450 * s)]),
        chapter(3, [seg(1, 450 * s)]),
      ],
    );

    test('plays as a single queue item', () {
      expect(t.queue, const [
        QueueItem(fileId: 1, clipStartMs: 0, clipEndMs: 600 * s),
      ]);
    });

    test('"next chapter" is a seek within the item, not a queue change', () {
      expect(t.queuePositionOfChapter(at(2, 0)), item(0, 200 * s));
      expect(t.queuePositionOfChapter(at(3, 0)), item(0, 450 * s));
    });

    test('converts both ways inside the file', () {
      expect(t.globalOf(at(3, 50 * s)), 500 * s);
      expect(t.chapterPositionAt(500 * s), at(3, 50 * s));
    });
  });

  group('layout 3: one chapter split across several files', () {
    final t = Timeline.build(
      files: const [
        TimelineFile(id: 1, durationMs: 100 * s),
        TimelineFile(id: 2, durationMs: 200 * s),
        TimelineFile(id: 3, durationMs: 50 * s),
      ],
      chapters: [
        chapter(1, [seg(1), seg(2), seg(3)]),
      ],
    );

    test('one chapter, three queue items', () {
      expect(t.queue, hasLength(3));
      expect(t.chapterDurationMs(1), 350 * s);
    });

    test('a position in the second file is still in the one chapter', () {
      expect(t.chapterPositionAt(150 * s), at(1, 150 * s));
      expect(t.queuePositionAt(150 * s), item(1, 50 * s));
      expect(t.globalOfQueue(item(2, 10 * s)), 310 * s);
    });
  });

  group('layout 4: files with no relationship to chapter boundaries', () {
    final t = diagramBook();

    test(
      'contiguous segments of the same file merge into one item per file',
      () {
        expect(t.queue, const [
          QueueItem(fileId: 1, clipStartMs: 0, clipEndMs: 40 * m),
          QueueItem(fileId: 2, clipStartMs: 0, clipEndMs: 35 * m),
          QueueItem(fileId: 3, clipStartMs: 0, clipEndMs: 50 * m),
        ]);
        expect(t.totalDurationMs, 125 * m);
      },
    );

    test('a chapter spanning a file boundary has the length of both parts', () {
      expect(t.chapterDurationMs(2), 30 * m);
      expect(t.chapterDurationMs(4), 25 * m);
    });

    test('a position past the file boundary inside a chapter lands in the next file', () {
      expect(t.globalOf(at(2, 27 * m)), 42 * m);
      expect(t.queuePositionOfChapter(at(2, 27 * m)), item(1, 2 * m));
    });

    test('a file boundary inside a chapter is not a chapter boundary', () {
      expect(t.chapterPositionAt(40 * m), at(2, 25 * m));
      expect(t.queuePositionAt(40 * m), item(1, 0));
    });

    test('every coordinate system round-trips across the whole book', () {
      // An odd step so sample points do not line up with any boundary by accident.
      for (var g = 0; g <= t.totalDurationMs; g += 7001) {
        expect(t.globalOf(t.chapterPositionAt(g)), g, reason: 'chapter at $g');
        expect(t.globalOfQueue(t.queuePositionAt(g)), g, reason: 'queue at $g');
      }
      final end = t.totalDurationMs;
      expect(t.globalOf(t.chapterPositionAt(end)), end);
      expect(t.globalOfQueue(t.queuePositionAt(end)), end);
    });
  });

  group('non-contiguous stretches of one file', () {
    final t = Timeline.build(
      files: const [TimelineFile(id: 1, durationMs: 100 * s)],
      chapters: [
        chapter(1, [seg(1, 0, 30 * s)]),
        chapter(2, [seg(1, 60 * s, 100 * s)]),
      ],
    );

    test('become separately clipped items, as §6.2 describes', () {
      expect(t.queue, const [
        QueueItem(fileId: 1, clipStartMs: 0, clipEndMs: 30 * s),
        QueueItem(fileId: 1, clipStartMs: 60 * s, clipEndMs: 100 * s),
      ]);
      expect(t.totalDurationMs, 70 * s);
    });

    test(
      'queue offsets are relative to the clip, file offsets are absolute',
      () {
        final p = t.queuePositionAt(35 * s);
        expect(p, item(1, 5 * s));
        expect(t.fileOffsetOf(p), 65 * s);
      },
    );
  });

  group('clamping', () {
    final t = diagramBook();

    test('global positions outside the book land at its ends', () {
      expect(t.chapterPositionAt(-5), at(1, 0));
      expect(t.chapterPositionAt(t.totalDurationMs + 99), at(6, 25 * m));
      expect(t.remainingMs(-1), t.totalDurationMs);
      expect(t.remainingMs(t.totalDurationMs + 1), 0);
    });

    test('an offset past the end of its chapter lands at the chapter end', () {
      expect(t.globalOf(at(1, 999 * m)), 15 * m);
      expect(t.globalOf(at(1, -10)), 0);
    });

    test('an offset past the end of its item lands at the item end', () {
      expect(t.globalOfQueue(item(0, 999 * m)), 40 * m);
    });
  });
}
