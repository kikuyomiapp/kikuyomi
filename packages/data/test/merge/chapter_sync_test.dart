import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:test/test.dart';

StoredChapter stored(
  int id,
  String key, {
  String? title,
  int? index,
  int? durationMs,
  DateTime? publishedAt,
  String? group,
  bool removed = false,
  bool progress = false,
  bool bookmarks = false,
  bool downloads = false,
}) => StoredChapter(
  id: id,
  key: key,
  title: title ?? 'Chapter $id',
  sourceIndex: index ?? id,
  durationMs: durationMs,
  publishedAt: publishedAt,
  group: group,
  removedFromSource: removed,
  hasProgress: progress,
  hasBookmarks: bookmarks,
  hasDownloads: downloads,
);

IncomingChapter incoming(
  String key, {
  required String title,
  required int index,
  int? durationMs,
  DateTime? publishedAt,
  String? group,
}) => IncomingChapter(
  key: key,
  title: title,
  sourceIndex: index,
  durationMs: durationMs,
  publishedAt: publishedAt,
  group: group,
);

void main() {
  group('matching by key', () {
    test('an unchanged book plans no changes', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a', durationMs: 60000)],
        incoming: [
          incoming('a', title: 'Chapter 1', index: 1, durationMs: 60000),
        ],
      );
      expect(plan, isEmpty);
    });

    test('a new key is inserted', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a')],
        incoming: [
          incoming('a', title: 'Chapter 1', index: 1),
          incoming('b', title: 'Chapter 2', index: 2),
        ],
      );
      expect(plan, hasLength(1));
      expect((plan.single as InsertChapter).chapter.key, 'b');
    });

    test('a reordered chapter is updated with its new index', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a', index: 1)],
        incoming: [incoming('a', title: 'Chapter 1', index: 5)],
      );
      final update = plan.single as UpdateChapter;
      expect(update.id, 1);
      expect(update.chapter.sourceIndex, 5);
      expect(update.restored, isFalse);
    });

    test('a retitled chapter keeping its key is updated, not renamed', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a', title: 'Old')],
        incoming: [incoming('a', title: 'New', index: 1)],
      );
      expect(plan.single, isA<UpdateChapter>());
    });

    test('a newly reported duration is an update', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a')],
        incoming: [
          incoming('a', title: 'Chapter 1', index: 1, durationMs: 90000),
        ],
      );
      expect((plan.single as UpdateChapter).chapter.durationMs, 90000);
    });

    test('a source that stops reporting a duration does not erase it', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a', durationMs: 90000)],
        incoming: [incoming('a', title: 'Chapter 1', index: 1)],
      );
      expect(plan, isEmpty);
    });
  });

  group('disappearing chapters', () {
    test('are soft-deleted, and purgeable when they carry nothing', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a')],
        incoming: const [],
      );
      final remove = plan.single as RemoveChapter;
      expect(remove.id, 1);
      expect(remove.purgeable, isTrue);
    });

    test(
      'are kept indefinitely when they carry progress, bookmarks or downloads',
      () {
        for (final chapter in [
          stored(1, 'a', progress: true),
          stored(2, 'b', bookmarks: true),
          stored(3, 'c', downloads: true),
        ]) {
          final plan = planChapterSync(stored: [chapter], incoming: const []);
          expect(
            (plan.single as RemoveChapter).purgeable,
            isFalse,
            reason: 'chapter ${chapter.id}',
          );
        }
      },
    );

    test('an already removed chapter that is still gone plans nothing', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a', removed: true)],
        incoming: const [],
      );
      expect(plan, isEmpty);
    });

    test('a removed chapter whose key returns is restored', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a', removed: true)],
        incoming: [incoming('a', title: 'Chapter 1', index: 1)],
      );
      final update = plan.single as UpdateChapter;
      expect(update.id, 1);
      expect(update.restored, isTrue);
    });
  });

  group('renames (§4.4 soft matching)', () {
    test('a changed key with the same title, index and duration keeps its identity', () {
      final plan = planChapterSync(
        stored: [
          stored(7, 'old-url', title: 'Intro', index: 0, durationMs: 60000),
        ],
        incoming: [
          incoming('new-url', title: 'Intro', index: 0, durationMs: 61500),
        ],
      );
      final rename = plan.single as RenameChapter;
      expect(rename.id, 7, reason: 'the stored id is what carries progress');
      expect(rename.previousKey, 'old-url');
      expect(rename.chapter.key, 'new-url');
    });

    test('the whole of a book surviving a URL scheme change', () {
      // The scenario §4.4 exists for: every key changes at once, nothing else does.
      final plan = planChapterSync(
        stored: [
          for (var i = 1; i <= 5; i++)
            stored(i, 'v1/$i', durationMs: i * 60000, progress: i < 3),
        ],
        incoming: [
          for (var i = 1; i <= 5; i++)
            incoming(
              'v2/chapter-$i',
              title: 'Chapter $i',
              index: i,
              durationMs: i * 60000,
            ),
        ],
      );
      expect(plan, hasLength(5));
      expect(plan, everyElement(isA<RenameChapter>()));
      expect(
        [for (final c in plan.cast<RenameChapter>()) c.id],
        [1, 2, 3, 4, 5],
      );
    });

    test('a duration unknown on either side does not prevent a rename', () {
      final plan = planChapterSync(
        stored: [stored(1, 'old', title: 'Intro', index: 0)],
        incoming: [
          incoming('new', title: 'Intro', index: 0, durationMs: 60000),
        ],
      );
      expect(plan.single, isA<RenameChapter>());
    });

    test('whitespace around a title does not prevent a rename', () {
      final plan = planChapterSync(
        stored: [stored(1, 'old', title: ' Intro ', index: 0)],
        incoming: [incoming('new', title: 'Intro', index: 0)],
      );
      expect(plan.single, isA<RenameChapter>());
    });

    group('is refused, falling back to insert and remove, when', () {
      void expectNoRename(List<ChapterChange> plan) {
        expect(plan.whereType<RenameChapter>(), isEmpty);
        expect(plan.whereType<InsertChapter>(), hasLength(1));
        expect(plan.whereType<RemoveChapter>(), hasLength(1));
      }

      test('the durations differ by more than the tolerance', () {
        expectNoRename(
          planChapterSync(
            stored: [
              stored(1, 'old', title: 'Intro', index: 0, durationMs: 60000),
            ],
            incoming: [
              incoming('new', title: 'Intro', index: 0, durationMs: 62001),
            ],
          ),
        );
      });

      test('the titles differ', () {
        expectNoRename(
          planChapterSync(
            stored: [stored(1, 'old', title: 'Intro', index: 0)],
            incoming: [incoming('new', title: 'Prologue', index: 0)],
          ),
        );
      });

      test('the indexes differ', () {
        expectNoRename(
          planChapterSync(
            stored: [stored(1, 'old', title: 'Intro', index: 0)],
            incoming: [incoming('new', title: 'Intro', index: 1)],
          ),
        );
      });

      test(
        'the titles are empty, which would pair chapters on index alone',
        () {
          expectNoRename(
            planChapterSync(
              stored: [stored(1, 'old', title: '', index: 0)],
              incoming: [incoming('new', title: '  ', index: 0)],
            ),
          );
        },
      );

      test('the chapter was removed in an earlier sync', () {
        final plan = planChapterSync(
          stored: [stored(1, 'old', title: 'Intro', index: 0, removed: true)],
          incoming: [incoming('new', title: 'Intro', index: 0)],
        );
        expect(plan.single, isA<InsertChapter>());
      });
    });

    test('an ambiguous match renames nothing', () {
      // Two stored chapters both fit one incoming chapter. Guessing would silently attach progress
      // to whichever was picked, so neither is chosen.
      final plan = planChapterSync(
        stored: [
          stored(1, 'a', title: 'Intro', index: 0, progress: true),
          stored(2, 'b', title: 'Intro', index: 0),
        ],
        incoming: [incoming('c', title: 'Intro', index: 0)],
      );
      expect(plan.whereType<RenameChapter>(), isEmpty);
      expect(plan.whereType<InsertChapter>(), hasLength(1));
      expect(plan.whereType<RemoveChapter>(), hasLength(2));
    });

    test('a custom tolerance is honoured', () {
      final plan = planChapterSync(
        stored: [stored(1, 'old', title: 'Intro', index: 0, durationMs: 60000)],
        incoming: [
          incoming('new', title: 'Intro', index: 0, durationMs: 70000),
        ],
        durationToleranceMs: 10000,
      );
      expect(plan.single, isA<RenameChapter>());
    });
  });

  test(
    'changes for incoming chapters come first, in source order, then removals',
    () {
      final plan = planChapterSync(
        stored: [stored(1, 'gone'), stored(2, 'kept', index: 2)],
        incoming: [
          incoming('fresh', title: 'Fresh', index: 1),
          incoming('kept', title: 'Chapter 2', index: 3),
        ],
      );
      expect(plan.map((c) => c.runtimeType).toList(), [
        InsertChapter,
        UpdateChapter,
        RemoveChapter,
      ]);
    },
  );

  test('a repeated key in either list is rejected', () {
    expect(
      () => planChapterSync(
        stored: [stored(1, 'a'), stored(2, 'a')],
        incoming: const [],
      ),
      throwsArgumentError,
    );
    expect(
      () => planChapterSync(
        stored: const [],
        incoming: [
          incoming('a', title: 'x', index: 0),
          incoming('a', title: 'y', index: 1),
        ],
      ),
      throwsArgumentError,
    );
  });

  group('a release time and a group heading', () {
    final released = DateTime.utc(2026, 3, 4);

    test('a chapter given a heading for the first time is updated', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a')],
        incoming: [
          incoming('a', title: 'Chapter 1', index: 1, group: 'Part One'),
        ],
      );

      expect(plan.single, isA<UpdateChapter>());
      expect((plan.single as UpdateChapter).chapter.group, 'Part One');
    });

    test('a chapter whose release time changed is updated', () {
      final plan = planChapterSync(
        stored: [stored(1, 'a', publishedAt: DateTime.utc(2026))],
        incoming: [
          incoming('a', title: 'Chapter 1', index: 1, publishedAt: released),
        ],
      );

      expect((plan.single as UpdateChapter).chapter.publishedAt, released);
    });

    test('a source that stops reporting either changes nothing', () {
      // The rule a duration already follows: sources drop fields through flakiness far more often
      // than on purpose, and a refresh that forgets a heading is worse than a stale one.
      final plan = planChapterSync(
        stored: [stored(1, 'a', publishedAt: released, group: 'Part One')],
        incoming: [incoming('a', title: 'Chapter 1', index: 1)],
      );

      expect(plan, isEmpty);
    });

    test('a heading does not make two chapters look like a rename', () {
      // Every chapter of a part shares its heading, so it tells none of them apart. Title and index
      // still decide, as they did before either field existed.
      final plan = planChapterSync(
        stored: [
          stored(1, 'old', title: 'Chapter 1', index: 1, group: 'Part One'),
        ],
        incoming: [
          incoming('new', title: 'Chapter 1', index: 1, group: 'Part Two'),
        ],
      );

      expect(plan.single, isA<RenameChapter>());
      expect((plan.single as RenameChapter).chapter.group, 'Part Two');
    });
  });
}
