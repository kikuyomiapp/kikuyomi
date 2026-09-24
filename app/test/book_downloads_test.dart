// Turning a handful of download_task rows into one sentence and one bar.
//
// The arithmetic is where an off-by-one shows up as a progress bar stuck at 99%, and the sentence is
// where a held queue becomes something a listener can act on, so both are tested without a widget.

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/downloads/book_downloads.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

final _at = DateTime.utc(2026, 9, 24, 9);

DownloadTaskRow task({
  int id = 1,
  DownloadState state = DownloadState.queued,
  DownloadHold? hold,
  int bytesDone = 0,
  int? bytesTotal,
}) => DownloadTaskRow(
  id: id,
  mediaFileId: 100 + id,
  state: state,
  hold: hold,
  priority: 0,
  bytesDone: bytesDone,
  bytesTotal: bytesTotal,
  attempts: 0,
  createdAt: _at,
  updatedAt: _at,
);

void main() {
  group('a book nobody asked for', () {
    test('has nothing to say', () {
      final downloads = summariseDownloads(const []);

      expect(downloads.isEmpty, isTrue);
      expect(downloads.isComplete, isFalse);
      expect(downloads.progress, isNull);
      expect(describeDownloads(downloads), 'Not downloaded');
    });
  });

  group('counting', () {
    test('what is here, what is moving, what gave up', () {
      final downloads = summariseDownloads([
        task(id: 1, state: DownloadState.completed),
        task(id: 2, state: DownloadState.downloading),
        task(id: 3, state: DownloadState.resolving),
        task(id: 4, state: DownloadState.failedRetryable),
        task(id: 5, state: DownloadState.queued),
      ]);

      expect(downloads.files, 5);
      expect(downloads.completed, 1);
      expect(downloads.active, 2);
      expect(downloads.failed, 1);
    });

    test('a book is complete only when every file is', () {
      expect(
        summariseDownloads([
          task(id: 1, state: DownloadState.completed),
          task(id: 2, state: DownloadState.completed),
        ]).isComplete,
        isTrue,
      );
      expect(
        summariseDownloads([
          task(id: 1, state: DownloadState.completed),
          task(id: 2, state: DownloadState.queued),
        ]).isComplete,
        isFalse,
      );
    });
  });

  group('progress', () {
    test('is bytes once every file has said what it is', () {
      final downloads = summariseDownloads([
        task(
          id: 1,
          state: DownloadState.downloading,
          bytesDone: 250,
          bytesTotal: 1000,
        ),
        task(
          id: 2,
          state: DownloadState.downloading,
          bytesDone: 250,
          bytesTotal: 1000,
        ),
      ]);

      expect(downloads.progress, closeTo(0.25, 0.001));
    });

    test('counts a finished file as all of itself', () {
      // Its last progress report may have arrived before the final bytes did.
      final downloads = summariseDownloads([
        task(
          id: 1,
          state: DownloadState.completed,
          bytesDone: 10,
          bytesTotal: 1000,
        ),
        task(id: 2, state: DownloadState.queued, bytesTotal: 1000),
      ]);

      expect(downloads.progress, closeTo(0.5, 0.001));
    });

    test('falls back to whole files while any size is unknown', () {
      // Coarse, but honest, and it never goes backwards — which a byte estimate mixed with guesses
      // would the moment a guess was corrected.
      final downloads = summariseDownloads([
        task(id: 1, state: DownloadState.completed, bytesTotal: 1000),
        task(id: 2, state: DownloadState.downloading, bytesDone: 900),
      ]);

      expect(downloads.bytesTotal, isNull);
      expect(downloads.progress, closeTo(0.5, 0.001));
    });

    test('never exceeds one', () {
      final downloads = summariseDownloads([
        task(
          id: 1,
          state: DownloadState.downloading,
          bytesDone: 5000,
          bytesTotal: 1000,
        ),
      ]);

      expect(downloads.progress, 1.0);
    });
  });

  group('what it says', () {
    test('when every file is here', () {
      expect(
        describeDownloads(
          summariseDownloads([task(state: DownloadState.completed)]),
        ),
        'Downloaded',
      );
    });

    test('while it is working', () {
      expect(
        describeDownloads(
          summariseDownloads([
            task(id: 1, state: DownloadState.completed),
            task(id: 2, state: DownloadState.downloading),
          ]),
        ),
        'Downloading 1 of 2',
      );
    });

    test('names what the queue is waiting for, not just that it waits', () {
      // "Waiting for Wi-Fi" is something a listener can act on; "waiting" makes them wonder whether
      // the app has stopped.
      String waitingOn(DownloadHold hold) => describeDownloads(
        summariseDownloads([task(state: DownloadState.waiting, hold: hold)]),
      );

      expect(waitingOn(DownloadHold.network), contains('Wi-Fi'));
      expect(waitingOn(DownloadHold.storage), contains('space'));
      expect(waitingOn(DownloadHold.slot), contains('turn'));
    });

    test('counts what could not be downloaded', () {
      expect(
        describeDownloads(
          summariseDownloads([task(state: DownloadState.failedPermanent)]),
        ),
        startsWith('One file could not be downloaded'),
      );
      expect(
        describeDownloads(
          summariseDownloads([
            task(id: 1, state: DownloadState.failedPermanent),
            task(id: 2, state: DownloadState.failedRetryable),
          ]),
        ),
        startsWith('2 files could not be downloaded'),
      );
    });

    test('says it is queued when nothing has begun', () {
      expect(
        describeDownloads(summariseDownloads([task()])),
        startsWith('Queued'),
      );
    });

    test('prefers what is happening to what went wrong', () {
      // One failure in a book still downloading should not read as a stopped download.
      expect(
        describeDownloads(
          summariseDownloads([
            task(id: 1, state: DownloadState.downloading),
            task(id: 2, state: DownloadState.failedRetryable),
          ]),
        ),
        startsWith('Downloading'),
      );
    });
  });

  test('a paused or cancelled file counts as none of the three', () {
    final downloads = summariseDownloads([
      task(id: 1, state: DownloadState.paused),
      task(id: 2, state: DownloadState.cancelled),
    ]);

    expect(downloads.active, 0);
    expect(downloads.failed, 0);
    expect(downloads.completed, 0);
    expect(downloads.isWorking, isFalse);
  });
}
