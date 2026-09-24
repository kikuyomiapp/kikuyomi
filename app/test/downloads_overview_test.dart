// Turning the queue's rows into the Downloads screen's list.
//
// The arithmetic is where a size adds up wrong and the ordering is where the book being fetched right
// now ends up under the eleven that finished last week, so both are tested without a widget.

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/downloads/downloads_overview.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

final _at = DateTime.utc(2026, 9, 24, 9);

var _nextId = 0;

DownloadEntry entry({
  int bookId = 1,
  String title = 'A Book',
  String fileKey = 'one.mp3',
  DownloadState state = DownloadState.queued,
  DownloadHold? hold,
  bool onDevice = false,
  int? sizeBytes,
  int bytesDone = 0,
  int? bytesTotal,
  String? lastError,
}) {
  final id = ++_nextId;
  return DownloadEntry(
    task: DownloadTaskRow(
      id: id,
      mediaFileId: 100 + id,
      state: state,
      hold: hold,
      priority: 0,
      bytesDone: bytesDone,
      bytesTotal: bytesTotal,
      attempts: 0,
      lastError: lastError,
      createdAt: _at,
      updatedAt: _at,
    ),
    bookId: bookId,
    bookTitle: title,
    fileKey: fileKey,
    isOnDevice: onDevice,
    sizeBytes: sizeBytes,
  );
}

void main() {
  setUp(() => _nextId = 0);

  group('grouping', () {
    test('gathers the files of one book under one row', () {
      final books = groupDownloads([
        entry(bookId: 7, title: 'Moby-Dick', fileKey: 'a.mp3'),
        entry(bookId: 7, title: 'Moby-Dick', fileKey: 'b.mp3'),
      ]);

      expect(books, hasLength(1));
      expect(books.single.bookId, 7);
      expect(books.single.title, 'Moby-Dick');
      expect(books.single.files, hasLength(2));
    });

    test('keeps the order the files arrived in', () {
      // Which is the order the source names them, and for most that is reading order.
      final books = groupDownloads([
        entry(fileKey: 'ch1.mp3'),
        entry(fileKey: 'ch2.mp3'),
        entry(fileKey: 'ch3.mp3'),
      ]);

      expect(
        [for (final file in books.single.files) file.fileKey],
        ['ch1.mp3', 'ch2.mp3', 'ch3.mp3'],
      );
    });

    test('counts and measures only what is really here', () {
      final books = groupDownloads([
        entry(onDevice: true, sizeBytes: 1000),
        entry(onDevice: true, sizeBytes: 2000),
        entry(sizeBytes: 9000),
      ]);

      expect(books.single.filesOnDevice, 2);
      expect(books.single.bytesOnDevice, 3000);
      expect(books.single.hasFilesOnDevice, isTrue);
    });

    test('a file whose size nothing stated adds nothing', () {
      final books = groupDownloads([
        entry(onDevice: true, sizeBytes: 500),
        entry(onDevice: true),
      ]);

      expect(books.single.filesOnDevice, 2);
      expect(books.single.bytesOnDevice, 500);
    });

    test('nothing at all is an empty list, not a row', () {
      expect(groupDownloads(const []), isEmpty);
    });
  });

  group('order', () {
    test('what is happening comes before what is not', () {
      final books = groupDownloads([
        entry(bookId: 1, title: 'Anatomy', state: DownloadState.completed),
        entry(bookId: 2, title: 'Zoology', state: DownloadState.downloading),
      ]);

      expect(
        [for (final book in books) book.title],
        ['Zoology', 'Anatomy'],
        reason: 'the book being fetched is what the screen exists to show',
      );
    });

    test('what needs attention comes before what is settled', () {
      final books = groupDownloads([
        entry(bookId: 1, title: 'Anatomy', state: DownloadState.completed),
        entry(
          bookId: 2,
          title: 'Zoology',
          state: DownloadState.failedPermanent,
        ),
      ]);

      expect([for (final book in books) book.title], ['Zoology', 'Anatomy']);
    });

    test('and a book that is working comes before one that failed', () {
      final books = groupDownloads([
        entry(bookId: 1, title: 'Failed', state: DownloadState.failedRetryable),
        entry(bookId: 2, title: 'Working', state: DownloadState.downloading),
      ]);

      expect([for (final book in books) book.title], ['Working', 'Failed']);
    });

    test('the rest go by title, whatever case it is written in', () {
      final books = groupDownloads([
        entry(bookId: 1, title: 'zoology', state: DownloadState.completed),
        entry(bookId: 2, title: 'Anatomy', state: DownloadState.completed),
        entry(bookId: 3, title: 'botany', state: DownloadState.completed),
      ]);

      expect(
        [for (final book in books) book.title],
        ['Anatomy', 'botany', 'zoology'],
      );
    });

    test('two books of the same name order the same way every time', () {
      // Without a last tiebreak the list would reorder itself under the listener's finger.
      for (var run = 0; run < 5; run++) {
        final books = groupDownloads([
          entry(bookId: 9, title: 'Same', state: DownloadState.completed),
          entry(bookId: 3, title: 'Same', state: DownloadState.completed),
        ]);
        expect([for (final book in books) book.bookId], [3, 9]);
      }
    });
  });

  test('the total is every book on the device', () {
    final books = groupDownloads([
      entry(bookId: 1, onDevice: true, sizeBytes: 1000),
      entry(bookId: 2, onDevice: true, sizeBytes: 2000),
      entry(bookId: 3, sizeBytes: 4000),
    ]);

    expect(totalBytesOnDevice(books), 3000);
  });

  group('what one file says', () {
    test('its size once it is here', () {
      expect(
        describeDownloadedFile(entry(onDevice: true, sizeBytes: 1536)),
        'Downloaded · 1.5 KB',
      );
    });

    test('and just that it is here when nothing said how big', () {
      expect(describeDownloadedFile(entry(onDevice: true)), 'Downloaded');
    });

    test('how far it has got while it is moving', () {
      expect(
        describeDownloadedFile(
          entry(
            state: DownloadState.downloading,
            bytesDone: 512,
            bytesTotal: 2048,
          ),
        ),
        'Downloading · 512 B of 2.0 KB',
      );
    });

    test('just that it is moving before the site has said how big', () {
      expect(
        describeDownloadedFile(entry(state: DownloadState.downloading)),
        'Downloading',
      );
    });

    test('what it is waiting for, not just that it waits', () {
      String held(DownloadHold hold) => describeDownloadedFile(
        entry(state: DownloadState.waiting, hold: hold),
      );

      expect(held(DownloadHold.network), contains('Wi-Fi'));
      expect(held(DownloadHold.storage), contains('space'));
      expect(held(DownloadHold.slot), contains('turn'));
    });

    test('what the site actually said when it failed', () {
      // The listener's only account of why a file is not here, so it is shown rather than a
      // paraphrase of it.
      expect(
        describeDownloadedFile(
          entry(
            state: DownloadState.failedPermanent,
            lastError: 'the file is not there any more',
          ),
        ),
        'the file is not there any more',
      );
    });

    test('and something plain when it failed without saying why', () {
      expect(
        describeDownloadedFile(entry(state: DownloadState.failedRetryable)),
        contains('tried again'),
      );
    });

    test('that a finished download has lost its file', () {
      // The row and the disk disagreeing, which a half-finished delete leaves behind. Saying so beats
      // showing it as downloaded and failing at the moment it is played.
      expect(
        describeDownloadedFile(entry(state: DownloadState.completed)),
        'Its file is missing',
      );
    });
  });

  group('sizes as a person reads them', () {
    test('bytes below a kilobyte', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
    });

    test('one decimal below ten, none above', () {
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(12 * 1024), '12 KB');
    });

    test('climbs through the units', () {
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('stops at terabytes rather than inventing a unit', () {
      expect(formatBytes(5000 * 1024 * 1024 * 1024), endsWith('TB'));
    });
  });
}
