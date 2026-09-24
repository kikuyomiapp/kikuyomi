// The Downloads screen's own wiring, without a database, a transport or a disk: what it shows about a
// book, what it offers to do with one, and what it refuses to offer.
//
// §5.6's three requirements are here — total usage, per-book sizes, a way to delete — and so is the
// one refusal that matters: nothing offers to delete a file that is not on the device.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/downloads/downloads_overview.dart';
import 'package:kikuyomi/src/downloads_view.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

final _at = DateTime.utc(2026, 9, 24, 9);

var _nextId = 0;

DownloadEntry entry({
  int bookId = 1,
  String title = 'Moby-Dick',
  String fileKey = 'one.mp3',
  DownloadState state = DownloadState.queued,
  bool onDevice = false,
  int? sizeBytes,
}) {
  final id = ++_nextId;
  return DownloadEntry(
    task: DownloadTaskRow(
      id: id,
      mediaFileId: 100 + id,
      state: state,
      priority: 0,
      bytesDone: 0,
      bytesTotal: sizeBytes,
      attempts: 0,
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

  late List<DownloadedBook> paused;
  late List<DownloadEntry> removedFiles;
  late List<DownloadEntry> retriedFiles;
  late List<DownloadedBook> removed;
  late List<DownloadedBook> cancelled;
  late List<DownloadedBook> resumed;
  late List<DownloadedBook> retried;
  late List<int> opened;

  setUp(() {
    paused = [];
    removedFiles = [];
    retriedFiles = [];
    removed = [];
    cancelled = [];
    resumed = [];
    retried = [];
    opened = [];
  });

  Future<void> pumpView(
    WidgetTester tester,
    List<DownloadEntry> entries, {
    int? busyWith,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        // A Scaffold, because the screen puts the view in one and a ListTile needs the Material it
        // brings with it.
        home: Scaffold(
          body: DownloadsView(
            books: groupDownloads(entries),
            busyWith: busyWith,
            onOpenBook: opened.add,
            onPauseBook: paused.add,
            onResumeBook: resumed.add,
            onCancelBook: cancelled.add,
            onRetryBook: retried.add,
            onRemoveBook: removed.add,
            onRemoveFile: removedFiles.add,
            onRetryFile: retriedFiles.add,
          ),
        ),
      ),
    );
  }

  /// Opens a book's overflow menu and returns once it is showing.
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<VoidCallback>).first);
    await tester.pumpAndSettle();
  }

  group('with nothing downloaded', () {
    testWidgets('says so, and says what to do about it', (tester) async {
      await pumpView(tester, const []);

      expect(find.text('Nothing downloaded'), findsOneWidget);
      expect(find.textContaining('Download'), findsWidgets);
    });
  });

  group('the total (§5.6)', () {
    testWidgets('is what the books come to on this device', (tester) async {
      await pumpView(tester, [
        entry(bookId: 1, onDevice: true, sizeBytes: 2 * 1024 * 1024),
        entry(bookId: 2, title: 'Another', onDevice: true, sizeBytes: 1024),
      ]);

      expect(find.textContaining('across 2 books'), findsOneWidget);
    });

    testWidgets('counts one book as one book', (tester) async {
      await pumpView(tester, [entry(onDevice: true, sizeBytes: 1024 * 1024)]);

      expect(find.textContaining('across 1 book'), findsOneWidget);
    });

    testWidgets('says nothing is here while it is all still coming', (
      tester,
    ) async {
      await pumpView(tester, [entry(state: DownloadState.downloading)]);

      expect(find.text('Nothing on this device yet'), findsOneWidget);
    });
  });

  group('a book', () {
    testWidgets('shows its title and what its queue is doing', (tester) async {
      await pumpView(tester, [
        entry(state: DownloadState.completed, onDevice: true, sizeBytes: 1024),
        entry(fileKey: 'two.mp3', state: DownloadState.downloading),
      ]);

      expect(find.text('Moby-Dick'), findsOneWidget);
      expect(find.textContaining('Downloading 1 of 2'), findsOneWidget);
    });

    testWidgets('shows a bar only while something is happening', (
      tester,
    ) async {
      await pumpView(tester, [entry(state: DownloadState.downloading)]);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      await pumpView(tester, [
        entry(state: DownloadState.completed, onDevice: true),
      ]);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('shows its size once its files are here', (tester) async {
      await pumpView(tester, [
        entry(
          state: DownloadState.completed,
          onDevice: true,
          sizeBytes: 3 * 1024 * 1024,
        ),
      ]);

      expect(find.textContaining('3.0 MB'), findsWidgets);
    });

    testWidgets('opens to its files, not to its chapters', (tester) async {
      // One file can hold thirty chapters and one chapter can span three files, so a list promising
      // chapters would be lying about what deleting one does.
      await pumpView(tester, [
        entry(fileKey: 'whale_bk.mp3', onDevice: true, sizeBytes: 1024),
        entry(fileKey: 'whale_rt.mp3'),
      ]);

      await tester.tap(find.text('Moby-Dick'));
      await tester.pumpAndSettle();

      expect(find.text('whale_bk.mp3'), findsOneWidget);
      expect(find.text('whale_rt.mp3'), findsOneWidget);
    });
  });

  group('what it offers to do', () {
    testWidgets('pausing and stopping, while something is happening', (
      tester,
    ) async {
      await pumpView(tester, [entry(state: DownloadState.downloading)]);

      await openMenu(tester);

      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Stop downloading'), findsOneWidget);
      expect(find.text('Resume'), findsNothing);
    });

    testWidgets('resuming, once something is paused', (tester) async {
      await pumpView(tester, [entry(state: DownloadState.paused)]);

      await openMenu(tester);

      expect(find.text('Resume'), findsOneWidget);
    });

    testWidgets('trying again, once something has failed', (tester) async {
      await pumpView(tester, [entry(state: DownloadState.failedPermanent)]);

      await openMenu(tester);

      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('removing, whatever state the book is in', (tester) async {
      // Always offered. Stopping a download leaves its rows behind, and a cancelled or given-up row
      // that nothing could remove would sit on this screen for the life of the library.
      for (final state in DownloadState.values) {
        await pumpView(tester, [entry(state: state)]);
        await openMenu(tester);

        expect(
          find.text('Remove from the list'),
          findsOneWidget,
          reason: 'nothing offered to remove a ${state.name} download',
        );

        await tester.tap(find.text('Open the book'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('and says it deletes, once there is something to delete', (
      tester,
    ) async {
      await pumpView(tester, [
        entry(state: DownloadState.completed, onDevice: true),
      ]);
      await openMenu(tester);

      expect(find.text('Delete and remove'), findsOneWidget);
      expect(find.text('Remove from the list'), findsNothing);
    });

    testWidgets('stopping, even when nothing is running yet', (tester) async {
      // A file queued behind another book's is not "working" and is very much worth being able to
      // stop before it starts.
      for (final state in [
        DownloadState.queued,
        DownloadState.paused,
        DownloadState.failedRetryable,
        DownloadState.needsResolve,
      ]) {
        await pumpView(tester, [entry(state: state)]);
        await openMenu(tester);

        expect(
          find.text('Stop downloading'),
          findsOneWidget,
          reason: 'nothing offered to stop a ${state.name} download',
        );

        await tester.tap(find.text('Open the book'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('but not for a book that has nothing left to do', (
      tester,
    ) async {
      await pumpView(tester, [
        entry(state: DownloadState.completed, onDevice: true),
      ]);
      await openMenu(tester);

      expect(find.text('Stop downloading'), findsNothing);
      expect(find.text('Pause'), findsNothing);
    });

    testWidgets('and each one tells the screen', (tester) async {
      await pumpView(tester, [entry(state: DownloadState.paused)]);

      await openMenu(tester);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();

      expect(resumed, hasLength(1));
      expect(resumed.single.bookId, 1);
    });

    testWidgets('opening the book it belongs to', (tester) async {
      await pumpView(tester, [entry(bookId: 42)]);

      await openMenu(tester);
      await tester.tap(find.text('Open the book'));
      await tester.pumpAndSettle();

      expect(opened, [42]);
    });
  });

  group('one file', () {
    testWidgets('can be deleted once it is here', (tester) async {
      await pumpView(tester, [
        entry(state: DownloadState.completed, onDevice: true, sizeBytes: 1024),
      ]);
      await tester.tap(find.text('Moby-Dick'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete this file'));
      await tester.pumpAndSettle();

      expect(removedFiles, hasLength(1));
    });

    testWidgets('can be removed before it is, in any state', (tester) async {
      for (final state in DownloadState.values) {
        // An empty list first, so the previous round's tile is gone rather than still expanded —
        // otherwise the tap below would close it instead of opening it.
        await pumpView(tester, const []);
        await pumpView(tester, [entry(state: state)]);
        await tester.tap(find.text('Moby-Dick'));
        await tester.pumpAndSettle();

        expect(
          find.byTooltip('Remove this file from the list'),
          findsOneWidget,
          reason: 'nothing offered to remove a ${state.name} file',
        );
      }
    });

    testWidgets('and removing it tells the screen', (tester) async {
      await pumpView(tester, [entry(state: DownloadState.cancelled)]);
      await tester.tap(find.text('Moby-Dick'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove this file from the list'));
      await tester.pumpAndSettle();

      expect(removedFiles, hasLength(1));
    });

    testWidgets('one that failed offers both trying again and removing', (
      tester,
    ) async {
      await pumpView(tester, [entry(state: DownloadState.failedPermanent)]);
      await tester.tap(find.text('Moby-Dick'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Try this file again'), findsOneWidget);
      expect(find.byTooltip('Remove this file from the list'), findsOneWidget);
    });

    testWidgets('can be tried again once it has failed', (tester) async {
      await pumpView(tester, [entry(state: DownloadState.failedPermanent)]);
      await tester.tap(find.text('Moby-Dick'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Try this file again'));
      await tester.pumpAndSettle();

      expect(retriedFiles, hasLength(1));
    });

    testWidgets('says what it is doing, and its own size', (tester) async {
      // Two files, so that the book's total and each file's size are different numbers and the line
      // under a file is unmistakably the file's own.
      await pumpView(tester, [
        entry(state: DownloadState.completed, onDevice: true, sizeBytes: 2048),
        entry(
          fileKey: 'two.mp3',
          state: DownloadState.completed,
          onDevice: true,
          sizeBytes: 4096,
        ),
      ]);
      await tester.tap(find.text('Moby-Dick'));
      await tester.pumpAndSettle();

      expect(find.text('Downloaded · 2.0 KB'), findsOneWidget);
      expect(find.text('Downloaded · 4.0 KB'), findsOneWidget);
      expect(
        find.text('Downloaded · 6.0 KB'),
        findsOneWidget,
        reason: 'and the book says what the two come to',
      );
      expect(find.text('6.0 KB across 1 book'), findsOneWidget);
    });
  });

  group('while a book is being worked on', () {
    testWidgets('it shows a spinner instead of its menu', (tester) async {
      await pumpView(tester, [
        entry(state: DownloadState.completed, onDevice: true),
      ], busyWith: 1);

      expect(find.byType(PopupMenuButton<VoidCallback>), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('and its files cannot be deleted twice', (tester) async {
      await pumpView(tester, [
        entry(state: DownloadState.completed, onDevice: true),
      ], busyWith: 1);
      await tester.tap(find.text('Moby-Dick'));
      // Pumped rather than settled: the busy spinner turns for ever, so there is nothing to settle to.
      await tester.pump(const Duration(seconds: 1));

      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.delete_outline),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('another book is left alone', (tester) async {
      await pumpView(tester, [
        entry(bookId: 1, onDevice: true, state: DownloadState.completed),
        entry(
          bookId: 2,
          title: 'Another',
          onDevice: true,
          state: DownloadState.completed,
        ),
      ], busyWith: 1);

      expect(find.byType(PopupMenuButton<VoidCallback>), findsOneWidget);
    });
  });
}
