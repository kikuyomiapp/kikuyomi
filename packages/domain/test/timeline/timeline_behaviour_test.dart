// The behaviours that justify the Timeline's design: why progress is chapter-relative, how
// embedded markers become virtual chapters, and the listened rule.

import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('duration refinement (§4.5)', () {
    // The first file was estimated at 40 minutes and probes 12 seconds longer, which is the exact
    // scenario §4.5 uses to justify storing progress chapter-relative.
    final before = diagramBook(firstFileEstimated: true);
    final after = diagramBook(firstFileMs: 40 * m + 12 * s);
    final saved = at(5, 100 * s);

    test('estimates are visible where they apply and nowhere else', () {
      expect(before.isEstimate, isTrue);
      expect(before.chapterDurationIsEstimate(1), isTrue);
      expect(before.chapterDurationIsEstimate(2), isTrue);
      expect(before.chapterDurationIsEstimate(3), isFalse);
      expect(before.chapterDurationIsEstimate(5), isFalse);
      expect(after.isEstimate, isFalse);
    });

    test(
      'a whole-file segment follows its file when the duration is refined',
      () {
        expect(
          after.chapterDurationMs(2) - before.chapterDurationMs(2),
          12 * s,
        );
      },
    );

    test('global positions after the refined file shift', () {
      expect(after.globalOf(saved) - before.globalOf(saved), 12 * s);
    });

    test(
      'a chapter-relative position resumes to the identical engine position',
      () {
        // Chapter 5 lives entirely in the third file, so the refinement must not move it at all.
        expect(
          after.queuePositionOfChapter(saved),
          before.queuePositionOfChapter(saved),
        );
      },
    );

    test('a stored global position would have resumed in the wrong place', () {
      // This is the failure chapter-relative storage exists to prevent.
      final storedGlobal = before.globalOf(saved);
      expect(after.chapterPositionAt(storedGlobal), isNot(saved));
      expect(after.chapterPositionAt(storedGlobal), at(5, 88 * s));
    });
  });

  group('learning a duration (§4.5)', () {
    final before = diagramBook(firstFileEstimated: true);

    test('the files a Timeline was built from can be looked up', () {
      expect(before.file(1).durationMs, 40 * m);
      expect(before.file(1).durationIsEstimate, isTrue);
      expect(before.file(3).durationIsEstimate, isFalse);
      expect(() => before.file(99), throwsArgumentError);
    });

    test('rebuilds the book as if the duration had been known all along', () {
      final learned = before.withLearnedDuration(1, 40 * m + 12 * s);
      final known = diagramBook(firstFileMs: 40 * m + 12 * s);

      expect(learned.file(1).durationMs, 40 * m + 12 * s);
      expect(learned.file(1).durationIsEstimate, isFalse);
      expect(learned.isEstimate, isFalse);
      expect(learned.totalDurationMs, before.totalDurationMs + 12 * s);
      expect(learned.queue, known.queue);
      expect(learned.navigation, known.navigation);
      expect(learned.chapterIds, before.chapterIds);
    });

    test('leaves the other files as they were', () {
      final book = Timeline.build(
        files: const [
          TimelineFile(id: 1, durationMs: 300 * s, durationIsEstimate: true),
          TimelineFile(id: 2, durationMs: 300 * s, durationIsEstimate: true),
        ],
        chapters: [
          chapter(1, [seg(1)]),
          chapter(2, [seg(2)]),
        ],
      );
      final learned = book.withLearnedDuration(1, 312 * s);
      expect(learned.file(2).durationMs, 300 * s);
      expect(learned.file(2).durationIsEstimate, isTrue);
      expect(learned.chapterDurationIsEstimate(1), isFalse);
      expect(learned.chapterDurationIsEstimate(2), isTrue);
    });

    test('keeps embedded markers, which may now reach further', () {
      final book = Timeline.build(
        files: const [
          TimelineFile(id: 1, durationMs: 1000 * s, durationIsEstimate: true),
        ],
        chapters: [
          chapter(1, [seg(1)]),
        ],
        markersByFile: const {
          1: [
            TimelineMarker(title: 'Opening', startMs: 0),
            TimelineMarker(title: 'Coda', startMs: 1050 * s),
          ],
        },
      );
      expect(book.navigation, const [
        MarkerEntry(title: 'Opening', startMs: 0, endMs: 1000 * s),
      ]);
      expect(book.withLearnedDuration(1, 1100 * s).navigation, const [
        MarkerEntry(title: 'Opening', startMs: 0, endMs: 1050 * s),
        MarkerEntry(title: 'Coda', startMs: 1050 * s, endMs: 1100 * s),
      ]);
    });

    test('a file the book does not have is rejected', () {
      expect(() => before.withLearnedDuration(99, 10 * m), throwsArgumentError);
    });

    test('a duration the layout cannot fit is rejected', () {
      // The first chapter ends 15 minutes into the first file, explicitly.
      expect(
        () => before.withLearnedDuration(1, 10 * m),
        throwsA(isA<InvalidTimelineException>()),
      );
    });
  });

  group('embedded markers as virtual chapters (§4.5)', () {
    const file = TimelineFile(id: 1, durationMs: 1000 * s);

    test('a single-chapter book navigates by its markers, in order', () {
      final t = Timeline.build(
        files: const [file],
        chapters: [
          chapter(1, [seg(1)]),
        ],
        markersByFile: const {
          1: [
            TimelineMarker(title: 'Part Three', startMs: 700 * s),
            TimelineMarker(title: 'Opening', startMs: 0),
            TimelineMarker(title: 'Part Two', startMs: 300 * s),
          ],
        },
      );
      expect(t.navigation, const [
        MarkerEntry(title: 'Opening', startMs: 0, endMs: 300 * s),
        MarkerEntry(title: 'Part Two', startMs: 300 * s, endMs: 700 * s),
        MarkerEntry(title: 'Part Three', startMs: 700 * s, endMs: 1000 * s),
      ]);
    });

    test('progress stays anchored to the source chapter, not the marker', () {
      final t = Timeline.build(
        files: const [file],
        chapters: [
          chapter(1, [seg(1)]),
        ],
        markersByFile: const {
          1: [
            TimelineMarker(title: 'Opening', startMs: 0),
            TimelineMarker(title: 'Part Two', startMs: 300 * s),
          ],
        },
      );
      final entry = t.navigationEntryAt(450 * s);
      final title = switch (entry) {
        MarkerEntry(:final title) => title,
        ChapterEntry() => fail('expected a marker entry'),
      };
      expect(title, 'Part Two');
      expect(t.chapterPositionAt(450 * s), at(1, 450 * s));
    });

    test('the stretch before the first marker still gets an entry', () {
      final t = Timeline.build(
        files: const [file],
        chapters: [
          chapter(1, [seg(1)]),
        ],
        markersByFile: const {
          1: [TimelineMarker(title: 'Later', startMs: 120 * s)],
        },
      );
      expect(t.navigation, const [
        MarkerEntry(title: 'Chapter 1', startMs: 0, endMs: 120 * s),
        MarkerEntry(title: 'Later', startMs: 120 * s, endMs: 1000 * s),
      ]);
    });

    test(
      'markers are file offsets, so a clipped chapter shifts and filters them',
      () {
        final t = Timeline.build(
          files: const [file],
          chapters: [
            chapter(1, [seg(1, 100 * s, 900 * s)]),
          ],
          markersByFile: const {
            1: [
              TimelineMarker(title: 'Before the clip', startMs: 0),
              TimelineMarker(title: 'Inside', startMs: 150 * s),
              TimelineMarker(title: 'After the clip', startMs: 950 * s),
            ],
          },
        );
        expect(t.navigation, const [
          MarkerEntry(title: 'Chapter 1', startMs: 0, endMs: 50 * s),
          MarkerEntry(title: 'Inside', startMs: 50 * s, endMs: 800 * s),
        ]);
      },
    );

    test('duplicate marker positions collapse to the first', () {
      final t = Timeline.build(
        files: const [file],
        chapters: [
          chapter(1, [seg(1)]),
        ],
        markersByFile: const {
          1: [
            TimelineMarker(title: 'A', startMs: 0),
            TimelineMarker(title: 'B', startMs: 0),
          ],
        },
      );
      expect(t.navigation, const [
        MarkerEntry(title: 'A', startMs: 0, endMs: 1000 * s),
      ]);
    });

    test(
      'a multi-chapter book ignores markers and navigates by its chapters',
      () {
        final t = Timeline.build(
          files: const [file],
          chapters: [
            chapter(1, [seg(1, 0, 400 * s)]),
            chapter(2, [seg(1, 400 * s)]),
          ],
          markersByFile: const {
            1: [TimelineMarker(title: 'Ignored', startMs: 100 * s)],
          },
        );
        expect(t.navigation, const [
          ChapterEntry(
            chapterId: 1,
            title: 'Chapter 1',
            startMs: 0,
            endMs: 400 * s,
          ),
          ChapterEntry(
            chapterId: 2,
            title: 'Chapter 2',
            startMs: 400 * s,
            endMs: 1000 * s,
          ),
        ]);
      },
    );

    test('navigation covers the whole book with no gaps', () {
      final t = diagramBook();
      var cursor = 0;
      for (final entry in t.navigation) {
        expect(entry.startMs, cursor);
        cursor = entry.endMs;
      }
      expect(cursor, t.totalDurationMs);
    });
  });

  group('the listened rule (§4.5)', () {
    test('a typical chapter allows 30 seconds of slack', () {
      expect(listenedThresholdMs(10 * m), 10 * m - 30 * s);
    });

    test('a long chapter allows 3 percent once that exceeds 30 seconds', () {
      expect(listenedThresholdMs(120 * m), 120 * m - 216 * s);
    });

    test('the two rules meet at 1000 seconds', () {
      expect(listenedThresholdMs(1000 * s), 970 * s);
    });

    test('a chapter of 30 seconds or less counts as listened once started', () {
      // Pinned deliberately: this is what the rule as written implies, and a change here should be
      // a conscious decision rather than an accident.
      expect(listenedThresholdMs(20 * s), 0);
      expect(listenedThresholdMs(30 * s), 0);
    });

    test('reaching the threshold counts, one millisecond short does not', () {
      final t = diagramBook();
      final threshold = listenedThresholdMs(t.chapterDurationMs(3));
      expect(t.isChapterListened(at(3, threshold)), isTrue);
      expect(t.isChapterListened(at(3, threshold - 1)), isFalse);
    });

    test('only listening to the last chapter finishes the book', () {
      final t = diagramBook();
      final lastThreshold = listenedThresholdMs(t.chapterDurationMs(6));
      final middleThreshold = listenedThresholdMs(t.chapterDurationMs(5));
      expect(t.lastChapterId, 6);
      expect(t.isBookFinished(at(6, lastThreshold)), isTrue);
      expect(t.isBookFinished(at(6, lastThreshold - 1)), isFalse);
      expect(t.isBookFinished(at(5, middleThreshold)), isFalse);
    });
  });
}
