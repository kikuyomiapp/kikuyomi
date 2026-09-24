// What the scheduler starts and what it holds back (§5.2).
//
// Three caps and two whole-queue conditions interact here, and the interesting cases are the ones
// where two of them apply at once. Every candidate gets a decision, so these tests check the reason a
// task is waiting as much as the fact of it: "waiting for Wi-Fi" and "waiting for a slot" are the
// difference between a listener knowing what to do and wondering whether the app is stuck.

import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_downloads/kikuyomi_downloads.dart';
import 'package:test/test.dart';

final _asked = DateTime.utc(2026, 9, 24, 9);

DownloadCandidate task(
  int id, {
  int source = 1,
  int priority = 0,
  int minutesLater = 0,
  int? bytesTotal,
}) => DownloadCandidate(
  taskId: id,
  sourceId: source,
  priority: priority,
  askedAt: _asked.add(Duration(minutes: minutesLater)),
  bytesTotal: bytesTotal,
);

/// Plenty of room and a connection nobody pays for.
DownloadConditions fine({Map<int, int> running = const {}}) =>
    DownloadConditions(
      network: NetworkKind.unmetered,
      freeSpaceBytes: 50 * 1024 * 1024 * 1024,
      runningBySource: running,
    );

List<int> started(List<DownloadDecision> decisions) => [
  for (final decision in decisions)
    if (decision is StartDownload) decision.taskId,
];

DownloadHold? holdOf(List<DownloadDecision> decisions, int taskId) {
  for (final decision in decisions) {
    if (decision.taskId == taskId && decision is HoldDownload) {
      return decision.reason;
    }
  }
  return null;
}

void main() {
  group('the global cap', () {
    test('starts no more than three at once', () {
      final decisions = chooseDownloads(
        candidates: [for (var i = 1; i <= 6; i++) task(i, source: i)],
        conditions: fine(),
      );

      expect(started(decisions), [1, 2, 3]);
      expect(holdOf(decisions, 4), DownloadHold.slot);
    });

    test('counts what is already running', () {
      final decisions = chooseDownloads(
        candidates: [task(1, source: 9), task(2, source: 10)],
        conditions: fine(running: {7: 1, 8: 1}),
      );

      expect(started(decisions), [1]);
      expect(holdOf(decisions, 2), DownloadHold.slot);
    });

    test('every candidate is answered, not only the ones held', () {
      final decisions = chooseDownloads(
        candidates: [for (var i = 1; i <= 5; i++) task(i, source: i)],
        conditions: fine(),
      );

      expect(decisions, hasLength(5));
    });
  });

  group('the per-source cap', () {
    test('holds a third file from one site while another site runs', () {
      // The cap is a promise to the site, not to the book: two books from one source share it.
      final decisions = chooseDownloads(
        candidates: [
          task(1, source: 1),
          task(2, source: 1),
          task(3, source: 1),
          task(4, source: 2),
        ],
        conditions: fine(),
      );

      expect(started(decisions), [1, 2, 4]);
      expect(holdOf(decisions, 3), DownloadHold.slot);
    });

    test('an extension may lower it', () {
      final decisions = chooseDownloads(
        candidates: [task(1), task(2), task(3)],
        limits: const DownloadLimits(perSource: 1),
        conditions: fine(),
      );

      expect(started(decisions), [1]);
    });

    test('counts what that source already has running', () {
      final decisions = chooseDownloads(
        candidates: [task(1, source: 4), task(2, source: 5)],
        conditions: fine(running: {4: 2}),
      );

      expect(started(decisions), [2]);
      expect(holdOf(decisions, 1), DownloadHold.slot);
    });
  });

  group('the network policy', () {
    test('holds everything when there is no connection', () {
      final decisions = chooseDownloads(
        candidates: [task(1), task(2)],
        conditions: const DownloadConditions(
          network: NetworkKind.none,
          freeSpaceBytes: 999999999999,
        ),
      );

      expect(started(decisions), isEmpty);
      expect(holdOf(decisions, 1), DownloadHold.network);
      expect(holdOf(decisions, 2), DownloadHold.network);
    });

    test('holds everything on a metered connection by default', () {
      // An audiobook is hundreds of megabytes, and finding that out from a phone bill is the worst
      // way to learn it.
      final decisions = chooseDownloads(
        candidates: [task(1)],
        conditions: const DownloadConditions(
          network: NetworkKind.metered,
          freeSpaceBytes: 999999999999,
        ),
      );

      expect(holdOf(decisions, 1), DownloadHold.network);
    });

    test('runs on a metered connection when the listener allows it', () {
      final decisions = chooseDownloads(
        candidates: [task(1)],
        limits: const DownloadLimits(unmeteredOnly: false),
        conditions: const DownloadConditions(
          network: NetworkKind.metered,
          freeSpaceBytes: 999999999999,
        ),
      );

      expect(started(decisions), [1]);
    });

    test(
      'still holds when there is no connection at all, however permissive',
      () {
        final decisions = chooseDownloads(
          candidates: [task(1)],
          limits: const DownloadLimits(unmeteredOnly: false),
          conditions: const DownloadConditions(
            network: NetworkKind.none,
            freeSpaceBytes: 999999999999,
          ),
        );

        expect(holdOf(decisions, 1), DownloadHold.network);
      },
    );
  });

  group('the free-space floor (§5.6)', () {
    test('holds everything once free space is at the floor', () {
      final decisions = chooseDownloads(
        candidates: [task(1), task(2)],
        limits: const DownloadLimits(freeSpaceFloorBytes: 1000),
        conditions: const DownloadConditions(
          network: NetworkKind.unmetered,
          freeSpaceBytes: 1000,
        ),
      );

      expect(started(decisions), isEmpty);
      expect(holdOf(decisions, 1), DownloadHold.storage);
    });

    test('holds a file that would cross the floor', () {
      final decisions = chooseDownloads(
        candidates: [task(1, bytesTotal: 600)],
        limits: const DownloadLimits(freeSpaceFloorBytes: 1000),
        conditions: const DownloadConditions(
          network: NetworkKind.unmetered,
          freeSpaceBytes: 1500,
        ),
      );

      expect(holdOf(decisions, 1), DownloadHold.storage);
    });

    test('lets a file of unknown size through', () {
      // The size is unknown precisely because the file has never started. Refusing every such task
      // would mean nothing was ever downloaded at all.
      final decisions = chooseDownloads(
        candidates: [task(1)],
        limits: const DownloadLimits(freeSpaceFloorBytes: 1000),
        conditions: const DownloadConditions(
          network: NetworkKind.unmetered,
          freeSpaceBytes: 1500,
        ),
      );

      expect(started(decisions), [1]);
    });

    test('counts what it has already decided to start in the same pass', () {
      // Two files that each fit but do not both fit. The second must be held, or the pass would
      // authorise more than the disk can take.
      final decisions = chooseDownloads(
        candidates: [
          task(1, source: 1, bytesTotal: 400),
          task(2, source: 2, bytesTotal: 400),
        ],
        limits: const DownloadLimits(freeSpaceFloorBytes: 1000),
        conditions: const DownloadConditions(
          network: NetworkKind.unmetered,
          freeSpaceBytes: 1500,
        ),
      );

      expect(started(decisions), [1]);
      expect(holdOf(decisions, 2), DownloadHold.storage);
    });
  });

  group('order', () {
    test('the most wanted take the free slots', () {
      final decisions = chooseDownloads(
        candidates: [
          task(1, source: 1, priority: 0),
          task(2, source: 2, priority: 10),
          task(3, source: 3, priority: 5),
          task(4, source: 4, priority: 0),
        ],
        limits: const DownloadLimits(atOnce: 2),
        conditions: fine(),
      );

      expect(started(decisions), [2, 3]);
    });

    test('equal priority is first come, first served', () {
      final decisions = chooseDownloads(
        candidates: [
          task(1, source: 1, minutesLater: 10),
          task(2, source: 2, minutesLater: 0),
        ],
        limits: const DownloadLimits(atOnce: 1),
        conditions: fine(),
      );

      expect(started(decisions), [2]);
    });

    test('the same instant orders the same way every run', () {
      // Without a last tiebreak, two tasks asked for in one millisecond would order differently from
      // one pass to the next, and a queue that shuffles itself is one nobody can follow.
      final candidates = [
        task(9, source: 1),
        task(3, source: 2),
        task(5, source: 3),
      ];

      for (var run = 0; run < 5; run++) {
        expect(
          started(
            chooseDownloads(
              candidates: candidates,
              limits: const DownloadLimits(atOnce: 2),
              conditions: fine(),
            ),
          ),
          [3, 5],
        );
      }
    });
  });

  test('nothing to do is not an error', () {
    expect(chooseDownloads(candidates: const [], conditions: fine()), isEmpty);
  });
}
