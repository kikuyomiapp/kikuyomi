// §5.3's state machine, move by move.
//
// Two kinds of test. The first walks the ordinary path a download takes and the detours the design
// names — a stale URL, a pause, a retry. The second is the one that earns its keep: it asserts that
// everything *not* drawn in §5.3 is refused, by trying every event against every state and comparing
// the whole set of legal moves against the diagram. A transition added by accident fails that test.

import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_downloads/kikuyomi_downloads.dart';
import 'package:test/test.dart';

/// Every event the machine knows, for sweeping the whole grid.
const events = <DownloadEvent>[
  DownloadResolutionStarted(),
  DownloadResolved(),
  DownloadHeld(DownloadHold.slot),
  DownloadReleased(),
  DownloadStarted(),
  DownloadPaused(),
  DownloadResumed(),
  DownloadUrlRejected(),
  DownloadBytesArrived(),
  DownloadProcessed(),
  DownloadFailed(permanent: false),
  DownloadFailed(permanent: true),
  DownloadRetryDue(),
  DownloadCancelled(),
];

String nameOf(DownloadEvent event) => switch (event) {
  DownloadFailed(:final permanent) => 'DownloadFailed(permanent: $permanent)',
  DownloadHeld(:final reason) => 'DownloadHeld(${reason.name})',
  _ => event.runtimeType.toString(),
};

void main() {
  group('the ordinary path', () {
    test('queued to completed, one move at a time', () {
      var state = DownloadState.queued;

      state = advance(state, const DownloadResolutionStarted())!;
      expect(state, DownloadState.resolving);

      state = advance(state, const DownloadResolved())!;
      expect(state, DownloadState.waiting);

      state = advance(state, const DownloadReleased())!;
      expect(state, DownloadState.downloading);

      state = advance(state, const DownloadBytesArrived())!;
      expect(state, DownloadState.processing);

      state = advance(state, const DownloadProcessed())!;
      expect(state, DownloadState.completed);
      expect(state.isFinished, isTrue);
    });

    test('a task with nothing in its way skips the waiting state', () {
      // The scheduler may hand a resolved task straight to the transport. Nobody should have to see
      // a "waiting" that lasted no time.
      expect(
        advance(DownloadState.resolving, const DownloadStarted()),
        DownloadState.downloading,
      );
    });
  });

  group('the detours §5.3 draws', () {
    test('a stale URL goes back to the extension, not to failure', () {
      // §5.4: a 403, a 410 or a passed expiry means the address was perishable, which is the source
      // working as designed. It must not count an attempt or look like an error.
      for (final from in [
        DownloadState.downloading,
        DownloadState.waiting,
        DownloadState.resolving,
      ]) {
        expect(
          advance(from, const DownloadUrlRejected()),
          DownloadState.needsResolve,
          reason: 'from $from',
        );
      }
      expect(
        advance(DownloadState.needsResolve, const DownloadResolutionStarted()),
        DownloadState.resolving,
      );
    });

    test('pausing stops a task that is waiting or queued, not only one that is moving', () {
      // A listener who pauses a book expects the whole book to stop, not just the one file that
      // happens to be moving bytes at that moment.
      for (final from in [
        DownloadState.downloading,
        DownloadState.waiting,
        DownloadState.queued,
      ]) {
        expect(
          advance(from, const DownloadPaused()),
          DownloadState.paused,
          reason: 'from $from',
        );
      }
    });

    test('resuming rejoins the queue rather than the transport', () {
      // The URL may have expired while it sat paused, and the caps may be full now, so the scheduler
      // decides afresh instead of the task walking back in.
      expect(
        advance(DownloadState.paused, const DownloadResumed()),
        DownloadState.queued,
      );
    });

    test('a retryable failure returns to the queue when its wait is over', () {
      expect(
        advance(DownloadState.failedRetryable, const DownloadRetryDue()),
        DownloadState.queued,
      );
      expect(
        advance(DownloadState.failedPermanent, const DownloadRetryDue()),
        isNull,
        reason: 'a permanent failure has no backoff to wait out',
      );
    });

    test('being held again for a different reason stays waiting', () {
      expect(
        advance(
          DownloadState.waiting,
          const DownloadHeld(DownloadHold.network),
        ),
        DownloadState.waiting,
      );
    });
  });

  group('what may happen from anywhere', () {
    test('cancelling, until it has finished', () {
      for (final from in DownloadState.values) {
        expect(
          advance(from, const DownloadCancelled()),
          from.isFinished ? isNull : DownloadState.cancelled,
          reason: 'from $from',
        );
      }
    });

    test('failing, until it has finished', () {
      for (final from in DownloadState.values) {
        expect(
          advance(from, const DownloadFailed(permanent: false)),
          from.isFinished ? isNull : DownloadState.failedRetryable,
          reason: 'from $from',
        );
        expect(
          advance(from, const DownloadFailed(permanent: true)),
          from.isFinished ? isNull : DownloadState.failedPermanent,
          reason: 'from $from',
        );
      }
    });
  });

  group('a report that no longer applies', () {
    test('is ignored rather than thrown', () {
      // The transport reports progress and completion whenever it gets round to it, which may be
      // after the listener cancelled. A machine that threw would turn that race into a crash.
      expect(
        advance(DownloadState.cancelled, const DownloadBytesArrived()),
        isNull,
      );
      expect(advance(DownloadState.completed, const DownloadStarted()), isNull);
      expect(
        advance(DownloadState.completed, const DownloadCancelled()),
        isNull,
        reason: 'cancelling a finished download would be a way to lose a file',
      );
    });

    test('canAdvance answers the same question without moving', () {
      expect(
        canAdvance(DownloadState.queued, const DownloadResolutionStarted()),
        isTrue,
      );
      expect(
        canAdvance(DownloadState.completed, const DownloadPaused()),
        isFalse,
      );
    });
  });

  test('the whole grid is exactly what §5.3 draws', () {
    // Every legal move, written out. Anything the machine allows that is not in this list, or that
    // this list has and the machine refuses, fails here — which is what stops a transition being
    // added by accident when some later feature finds it convenient.
    const drawn = {
      'queued + DownloadResolutionStarted -> resolving',
      'queued + DownloadPaused -> paused',
      'queued + DownloadFailed(permanent: false) -> failedRetryable',
      'queued + DownloadFailed(permanent: true) -> failedPermanent',
      'queued + DownloadCancelled -> cancelled',
      'resolving + DownloadResolved -> waiting',
      'resolving + DownloadStarted -> downloading',
      'resolving + DownloadHeld(slot) -> waiting',
      'resolving + DownloadUrlRejected -> needsResolve',
      'resolving + DownloadFailed(permanent: false) -> failedRetryable',
      'resolving + DownloadFailed(permanent: true) -> failedPermanent',
      'resolving + DownloadCancelled -> cancelled',
      'waiting + DownloadReleased -> downloading',
      'waiting + DownloadStarted -> downloading',
      'waiting + DownloadHeld(slot) -> waiting',
      'waiting + DownloadPaused -> paused',
      'waiting + DownloadUrlRejected -> needsResolve',
      'waiting + DownloadFailed(permanent: false) -> failedRetryable',
      'waiting + DownloadFailed(permanent: true) -> failedPermanent',
      'waiting + DownloadCancelled -> cancelled',
      'downloading + DownloadPaused -> paused',
      'downloading + DownloadUrlRejected -> needsResolve',
      'downloading + DownloadBytesArrived -> processing',
      'downloading + DownloadFailed(permanent: false) -> failedRetryable',
      'downloading + DownloadFailed(permanent: true) -> failedPermanent',
      'downloading + DownloadCancelled -> cancelled',
      'paused + DownloadResumed -> queued',
      'paused + DownloadFailed(permanent: false) -> failedRetryable',
      'paused + DownloadFailed(permanent: true) -> failedPermanent',
      'paused + DownloadCancelled -> cancelled',
      'needsResolve + DownloadResolutionStarted -> resolving',
      'needsResolve + DownloadFailed(permanent: false) -> failedRetryable',
      'needsResolve + DownloadFailed(permanent: true) -> failedPermanent',
      'needsResolve + DownloadCancelled -> cancelled',
      'processing + DownloadProcessed -> completed',
      'processing + DownloadFailed(permanent: false) -> failedRetryable',
      'processing + DownloadFailed(permanent: true) -> failedPermanent',
      'processing + DownloadCancelled -> cancelled',
      'failedRetryable + DownloadRetryDue -> queued',
      'failedRetryable + DownloadFailed(permanent: false) -> failedRetryable',
      'failedRetryable + DownloadFailed(permanent: true) -> failedPermanent',
      'failedRetryable + DownloadCancelled -> cancelled',
    };

    final actual = <String>{};
    for (final from in DownloadState.values) {
      for (final event in events) {
        final to = advance(from, event);
        if (to != null) {
          actual.add('${from.name} + ${nameOf(event)} -> ${to.name}');
        }
      }
    }

    expect(actual, drawn);
  });
}
