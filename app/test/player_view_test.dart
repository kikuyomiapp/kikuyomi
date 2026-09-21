import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/bookmark_commands.dart';
import 'package:kikuyomi/src/bookmark_list.dart';
import 'package:kikuyomi/src/chapter_list.dart';
import 'package:kikuyomi/src/format.dart';
import 'package:kikuyomi/src/player_shortcuts.dart';
import 'package:kikuyomi/src/player_view.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart' show BookmarkOverview;
import 'package:kikuyomi_design_system/kikuyomi_design_system.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart'
    show ChapterPosition, MarkerEntry, NavigationEntry;
import 'package:kikuyomi_playback/kikuyomi_playback.dart'
    show
        PlayerReady,
        SleepAfter,
        SleepAtEndOfChapter,
        SleepTimerOff,
        SleepTimerRunning,
        SleepTimerState;

/// The book the player shows: three chapters, playback 5 seconds into the second.
const chapters = [
  MarkerEntry(title: 'Chapter One', startMs: 0, endMs: 60000),
  MarkerEntry(title: 'Chapter Two', startMs: 60000, endMs: 120000),
  MarkerEntry(title: 'Chapter Three', startMs: 120000, endMs: 3725000),
];

PlayerReady readyAt({
  bool playing = false,
  SleepTimerState sleepTimer = const SleepTimerOff(),
  NavigationEntry? entry,
  List<NavigationEntry> navigation = chapters,
  double speed = 1.0,
}) => PlayerReady(
  bookId: 1,
  position: const ChapterPosition(chapterId: 1, offsetMs: 65000),
  globalMs: 65000,
  totalMs: 3725000,
  entry: entry ?? chapters[1],
  navigation: navigation,
  playing: playing,
  buffering: false,
  speed: speed,
  sleepTimer: sleepTimer,
  finished: false,
);

/// A bookmark in the book the player shows, [globalMs] into it. Only an unnamed one [removed] from
/// the book or not [placed] in it has no global position.
BookmarkOverview bookmarkAt(
  int id,
  int globalMs, {
  String? title,
  String? note,
  String chapterTitle = 'Chapter Two',
  bool removed = false,
  bool placed = true,
}) => BookmarkOverview(
  bookmarkId: id,
  bookId: 1,
  chapterId: 1,
  chapterPositionMs: globalMs,
  title: title,
  note: note,
  createdAt: DateTime.utc(2026, 9, 14),
  chapterTitle: chapterTitle,
  globalPositionMs: removed || !placed ? null : globalMs,
  removedFromSource: removed,
);

/// A player view for [state], [cover] and [bookmarks], with its keyboard shortcuts around it as the
/// player screen has them, that records in [pressed] what was pressed and what was asked of the
/// bookmarks. A bookmark added gets the id 7.
Widget player(
  PlayerReady state, {
  List<String>? pressed,
  File? cover,
  List<BookmarkOverview> bookmarks = const [],
}) {
  void press(String what) => pressed?.add(what);
  void playPause() => press('play');
  void skip(Duration by) => press('skip ${by.inSeconds}');
  void speed(double to) => press('speed $to');
  final commands = BookmarkCommands(
    add: () async {
      press('bookmark');
      return 7;
    },
    rename: (id, title) async => press('rename $id $title'),
    setNote: (id, note) async => press('note $id $note'),
    delete: (bookmark) async => press('delete ${bookmark.bookmarkId}'),
    restore: (bookmark) async => press('restore ${bookmark.bookmarkId}'),
  );
  return MaterialApp(
    home: Builder(
      builder: (context) => PlayerShortcuts(
        state: state,
        onPlayPause: playPause,
        onSkip: skip,
        onSpeed: speed,
        onAddBookmark: () => addBookmarkHere(context, commands),
        child: Scaffold(
          body: PlayerView(
            title: 'A Book',
            cover: cover,
            state: state,
            bookmarks: bookmarks,
            bookmarkCommands: commands,
            onPlayPause: playPause,
            onSeek: (ms) => press('seek $ms'),
            onSkip: skip,
            onPreviousChapter: () => press('previous'),
            onNextChapter: () => press('next'),
            onSpeed: speed,
            onSleepTimer: (target) => press(switch (target) {
              SleepAfter(:final duration) => 'sleep ${duration.inMinutes}',
              SleepAtEndOfChapter() => 'sleep at end of chapter',
            }),
            onCancelSleepTimer: () => press('sleep off'),
          ),
        ),
      ),
    ),
  );
}

/// Makes the test window as wide as a desktop one, which the chapter side panel needs.
void useWideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Opens or closes the chapters and bookmarks: the side panel on a wide screen, the sheet on a
/// narrow one, at whichever of the two was last shown.
Future<void> toggleChapters(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Chapters and bookmarks'));
  await tester.pumpAndSettle();
}

/// Opens the bookmarks, in the side panel or the sheet.
Future<void> showBookmarks(WidgetTester tester) async {
  await toggleChapters(tester);
  await tester.tap(find.text('Bookmarks'));
  await tester.pumpAndSettle();
}

/// [text] in the chapter list, rather than on the player under it.
Finder inList(String text) =>
    find.descendant(of: find.byType(ChapterList), matching: find.text(text));

/// [text] in the list of bookmarks.
Finder inBookmarks(String text) =>
    find.descendant(of: find.byType(BookmarkList), matching: find.text(text));

/// The row of the bookmark that shows [text].
Finder bookmarkRow(String text) =>
    find.ancestor(of: inBookmarks(text), matching: find.byType(ListTile));

/// Picks [item] from the menu of the bookmark named [name].
Future<void> fromMenu(WidgetTester tester, String name, String item) async {
  await tester.tap(find.byTooltip('Options for $name'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

void main() {
  test('clock formatting', () {
    expect(formatClock(0), '0:00');
    expect(formatClock(65000), '1:05');
    expect(formatClock(3725000), '1:02:05');
    expect(formatClock(-5), '0:00');
  });

  testWidgets('shows the book, the chapter and the time', (tester) async {
    await tester.pumpWidget(player(readyAt()));
    expect(find.text('A Book'), findsOneWidget);
    expect(find.text('Chapter Two'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.text('-1:01:00'), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
  });

  testWidgets('offers pause while playing', (tester) async {
    await tester.pumpWidget(player(readyAt(playing: true)));
    expect(find.byTooltip('Pause'), findsOneWidget);
  });

  testWidgets('the transport buttons report what was pressed', (tester) async {
    final pressed = <String>[];
    await tester.pumpWidget(player(readyAt(), pressed: pressed));
    await tester.tap(find.byTooltip('Play'));
    await tester.tap(find.byTooltip('Back 30 seconds'));
    await tester.tap(find.byTooltip('Forward 30 seconds'));
    await tester.tap(find.byTooltip('Previous chapter'));
    await tester.tap(find.byTooltip('Next chapter'));
    expect(pressed, ['play', 'skip -30', 'skip 30', 'previous', 'next']);
  });

  group('the cover', () {
    final coverFile = File('covers/1.jpg');
    final cover = find.byType(BookCover);

    Future<void> showIn(WidgetTester tester, Size window) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(player(readyAt(), cover: coverFile));
    }

    testWidgets('sits above the title, at full size where there is room', (
      tester,
    ) async {
      await showIn(tester, const Size(800, 1000));

      final shown = tester.widget<BookCover>(cover);
      expect(shown.file!.path, coverFile.path);
      expect(shown.semanticLabel, 'Cover of A Book');
      expect(tester.getSize(cover), const Size(320, 320));
      expect(
        tester.getBottomLeft(cover).dy,
        lessThan(tester.getTopLeft(find.text('A Book')).dy),
      );
    });

    testWidgets('narrows to fit a narrow phone', (tester) async {
      await showIn(tester, const Size(360, 900));
      expect(tester.getSize(cover), const Size(312, 312));
    });

    testWidgets('shrinks to fit a short window', (tester) async {
      await showIn(tester, const Size(1024, 560));

      final height = tester.getSize(cover).height;
      expect(height, lessThan(320));
      expect(height, greaterThanOrEqualTo(96));
      expect(tester.takeException(), isNull);
    });

    testWidgets('is left out where there is no room for it', (tester) async {
      await showIn(tester, const Size(1024, 420));
      expect(cover, findsNothing);
      expect(find.text('A Book'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the sleep timer', () {
    Future<void> choose(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('Sleep timer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('is set from its menu', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await choose(tester, '30 minutes');
      await choose(tester, 'End of chapter');
      expect(pressed, ['sleep 30', 'sleep at end of chapter']);
    });

    testWidgets('offers no "Off" while no timer is set', (tester) async {
      await tester.pumpWidget(player(readyAt()));
      await tester.tap(find.byTooltip('Sleep timer'));
      await tester.pumpAndSettle();
      expect(find.text('Off'), findsNothing);
    });

    testWidgets('shows the time left while it runs, and turns off', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        player(
          readyAt(
            sleepTimer: const SleepTimerRunning(
              remaining: Duration(minutes: 14, seconds: 5),
              volume: 1.0,
            ),
          ),
          pressed: pressed,
        ),
      );
      expect(find.text('14:05'), findsOneWidget);
      await choose(tester, 'Off');
      expect(pressed, ['sleep off']);
    });
  });

  group('the chapter list', () {
    ListTile row(WidgetTester tester, String title) => tester.widget(
      find.ancestor(of: inList(title), matching: find.byType(ListTile)),
    );

    testWidgets('shows every chapter with its length, the current one marked', (
      tester,
    ) async {
      await tester.pumpWidget(player(readyAt()));
      await toggleChapters(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      for (final entry in chapters) {
        expect(inList(entry.title), findsOneWidget);
      }
      expect(inList('1:00'), findsNWidgets(2));
      expect(inList('1:00:05'), findsOneWidget);
      expect(row(tester, 'Chapter One').selected, isFalse);
      expect(row(tester, 'Chapter Two').selected, isTrue);
      expect(row(tester, 'Chapter Three').selected, isFalse);
      expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(
            of: inList('Chapter Two'),
            matching: find.byType(ListTile),
          ),
          matching: find.byIcon(Icons.graphic_eq),
        ),
        findsOneWidget,
      );
    });

    testWidgets('picking a chapter seeks to its start and closes the list', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await toggleChapters(tester);
      await tester.tap(inList('Chapter Three'));
      await tester.pumpAndSettle();

      expect(pressed, ['seek 120000']);
      expect(find.byType(ChapterList), findsNothing);
    });

    testWidgets('opens scrolled to the current chapter', (tester) async {
      final many = [
        for (var i = 0; i < 40; i++)
          MarkerEntry(
            title: 'Chapter ${i + 1}',
            startMs: i * 60000,
            endMs: (i + 1) * 60000,
          ),
      ];
      await tester.pumpWidget(
        player(readyAt(entry: many[30], navigation: many)),
      );
      await toggleChapters(tester);

      expect(inList('Chapter 31').hitTestable(), findsOneWidget);
      expect(inList('Chapter 1'), findsNothing);
    });

    testWidgets('on a wide screen opens beside the controls and stays open', (
      tester,
    ) async {
      useWideWindow(tester);
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));

      await toggleChapters(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(row(tester, 'Chapter Two').selected, isTrue);

      await tester.tap(inList('Chapter One'));
      await tester.pumpAndSettle();
      expect(pressed, ['seek 0']);
      expect(find.byType(ChapterList), findsOneWidget);

      await toggleChapters(tester);
      expect(find.byType(ChapterList), findsNothing);
    });
  });

  group('adding a bookmark', () {
    testWidgets('the bookmark button adds one, and says so', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await tester.tap(find.byTooltip('Add bookmark'));
      await tester.pumpAndSettle();

      expect(pressed, ['bookmark']);
      expect(find.text('Bookmark added'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'Add note'), findsOneWidget);
    });

    testWidgets('the message adds a note to the bookmark just added', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await tester.tap(find.byTooltip('Add bookmark'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SnackBarAction, 'Add note'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AlertDialog, 'Add note'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Listen again');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(pressed, ['bookmark', 'note 7 Listen again']);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the message goes by itself after a few seconds', (
      tester,
    ) async {
      await tester.pumpWidget(player(readyAt()));
      await tester.tap(find.byTooltip('Add bookmark'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Bookmark added'), findsNothing);
    });

    testWidgets('the message stays for someone using a screen reader', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(player(readyAt()));
      await tester.tap(find.byTooltip('Add bookmark'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.text('Bookmark added'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Bookmark added'), findsNothing);
    });
  });

  group('the bookmarks', () {
    final named = bookmarkAt(
      1,
      65000,
      title: 'The twist',
      note: 'Listen again',
    );
    final unnamed = bookmarkAt(2, 125000, chapterTitle: 'Chapter Three');

    testWidgets('show each name, place and note, next to the chapters', (
      tester,
    ) async {
      await tester.pumpWidget(player(readyAt(), bookmarks: [named, unnamed]));
      await showBookmarks(tester);

      expect(find.byType(ChapterList), findsNothing);
      expect(inBookmarks('The twist'), findsOneWidget);
      expect(inBookmarks('1:05 · Chapter Two'), findsOneWidget);
      expect(inBookmarks('Listen again'), findsOneWidget);
      // One with no name of its own goes by its chapter's.
      expect(inBookmarks('Chapter Three'), findsOneWidget);
      expect(inBookmarks('2:05'), findsOneWidget);

      await tester.tap(find.text('Chapters'));
      await tester.pumpAndSettle();
      expect(find.byType(BookmarkList), findsNothing);
      expect(inList('Chapter Three'), findsOneWidget);
    });

    testWidgets('say how to add one while there are none', (tester) async {
      await tester.pumpWidget(player(readyAt()));
      await showBookmarks(tester);
      expect(find.textContaining('No bookmarks yet'), findsOneWidget);
    });

    testWidgets('picking one seeks to it and closes the sheet', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        player(readyAt(), pressed: pressed, bookmarks: [named, unnamed]),
      );
      await showBookmarks(tester);
      await tester.tap(inBookmarks('Chapter Three'));
      await tester.pumpAndSettle();

      expect(pressed, ['seek 125000']);
      expect(find.byType(BookmarkList), findsNothing);
    });

    testWidgets('on a wide screen open beside the controls and stay open', (
      tester,
    ) async {
      useWideWindow(tester);
      final pressed = <String>[];
      await tester.pumpWidget(
        player(readyAt(), pressed: pressed, bookmarks: [named]),
      );
      await showBookmarks(tester);
      expect(find.byType(BottomSheet), findsNothing);

      await tester.tap(inBookmarks('The twist'));
      await tester.pumpAndSettle();
      expect(pressed, ['seek 65000']);
      expect(find.byType(BookmarkList), findsOneWidget);

      // Closed and opened again, the panel is still at the bookmarks.
      await toggleChapters(tester);
      await toggleChapters(tester);
      expect(find.byType(BookmarkList), findsOneWidget);
    });

    testWidgets('mark one whose chapter was removed, and do not seek to it', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        player(
          readyAt(),
          pressed: pressed,
          bookmarks: [
            bookmarkAt(3, 60000, chapterTitle: 'Old chapter', removed: true),
          ],
        ),
      );
      await showBookmarks(tester);

      expect(
        inBookmarks('1:00 into the chapter · Chapter removed from the book'),
        findsOneWidget,
      );
      expect(find.byTooltip('Its chapter is no longer in the book'), findsOne);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      await tester.tap(inBookmarks('Old chapter'));
      await tester.pumpAndSettle();
      expect(pressed, isEmpty);
      expect(find.byType(BookmarkList), findsOneWidget);
    });

    testWidgets('mark one whose chapter cannot be played yet', (tester) async {
      await tester.pumpWidget(
        player(readyAt(), bookmarks: [bookmarkAt(4, 5000, placed: false)]),
      );
      await showBookmarks(tester);
      expect(
        inBookmarks('0:05 into the chapter · Cannot be played yet'),
        findsOneWidget,
      );
      expect(tester.widget<ListTile>(bookmarkRow('Chapter Two')).onTap, isNull);
    });

    testWidgets('are read out, and picked, with a screen reader', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        player(
          readyAt(),
          bookmarks: [
            named,
            bookmarkAt(3, 60000, chapterTitle: 'Old chapter', removed: true),
          ],
        ),
      );
      expect(
        tester.getSemantics(find.byTooltip('Add bookmark')),
        isSemantics(
          tooltip: 'Add bookmark',
          isButton: true,
          hasTapAction: true,
        ),
      );
      await showBookmarks(tester);

      expect(
        tester.getSemantics(bookmarkRow('The twist')),
        isSemantics(
          label: 'The twist\n1:05 · Chapter Two\nListen again',
          tooltip: 'Go to 1:05',
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(bookmarkRow('Old chapter')),
        isSemantics(
          label: 'Old chapter\n1:00 into the chapter · Chapter removed from the book',
          tooltip: 'Its chapter is no longer in the book',
          isButton: false,
          hasTapAction: false,
        ),
      );
      expect(
        tester.getSemantics(find.byTooltip('Options for Old chapter')),
        isSemantics(isButton: true, hasTapAction: true),
      );
      semantics.dispose();
    });

    testWidgets('keep up with changes while the sheet is open', (tester) async {
      await tester.pumpWidget(player(readyAt(), bookmarks: [named, unnamed]));
      await showBookmarks(tester);
      expect(inBookmarks('Chapter Three'), findsOneWidget);

      await tester.pumpWidget(
        player(
          readyAt(),
          bookmarks: [
            bookmarkAt(1, 65000, title: 'Renamed', note: 'Listen again'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(inBookmarks('Renamed'), findsOneWidget);
      expect(inBookmarks('Chapter Three'), findsNothing);
    });

    group('from the menu', () {
      testWidgets('are renamed, and Enter saves the name', (tester) async {
        final pressed = <String>[];
        await tester.pumpWidget(
          player(readyAt(), pressed: pressed, bookmarks: [named]),
        );
        await showBookmarks(tester);
        await fromMenu(tester, 'The twist', 'Rename');

        expect(find.widgetWithText(AlertDialog, 'Rename bookmark'), findsOne);
        final field = tester.widget<TextField>(find.byType(TextField));
        // The name is there to change, and all of it selected, so typing replaces it.
        expect(field.controller!.text, 'The twist');
        expect(
          field.controller!.selection.textInside('The twist'),
          'The twist',
        );
        await tester.enterText(find.byType(TextField), 'Plot twist');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(pressed, ['rename 1 Plot twist']);
      });

      testWidgets('are noted, and Ctrl+Enter saves the note', (tester) async {
        final pressed = <String>[];
        await tester.pumpWidget(
          player(readyAt(), pressed: pressed, bookmarks: [unnamed]),
        );
        await showBookmarks(tester);
        await fromMenu(tester, 'Chapter Three', 'Add note');

        await tester.enterText(find.byType(TextField), 'First line\nSecond');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(pressed, ['note 2 First line\nSecond']);
      });

      testWidgets('offer to edit a note there already is', (tester) async {
        final pressed = <String>[];
        await tester.pumpWidget(
          player(readyAt(), pressed: pressed, bookmarks: [named]),
        );
        await showBookmarks(tester);
        await fromMenu(tester, 'The twist', 'Edit note');

        expect(find.widgetWithText(AlertDialog, 'Edit note'), findsOneWidget);
        await tester.enterText(find.byType(TextField), '');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(pressed, ['note 1 ']);
      });

      testWidgets('are left as they were when Escape cancels', (tester) async {
        final pressed = <String>[];
        await tester.pumpWidget(
          player(readyAt(), pressed: pressed, bookmarks: [named]),
        );
        await showBookmarks(tester);
        await fromMenu(tester, 'The twist', 'Rename');
        await tester.enterText(find.byType(TextField), 'Not this');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(pressed, isEmpty);
      });

      testWidgets('are deleted, with a way to undo it in the sheet', (
        tester,
      ) async {
        final pressed = <String>[];
        await tester.pumpWidget(
          player(readyAt(), pressed: pressed, bookmarks: [named, unnamed]),
        );
        await showBookmarks(tester);
        await fromMenu(tester, 'The twist', 'Delete');

        expect(pressed, ['delete 1']);
        // In the sheet, where it can be reached, rather than behind it.
        expect(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Bookmark deleted'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
        await tester.pumpAndSettle();
        expect(pressed, ['delete 1', 'restore 1']);
      });

      testWidgets('are deleted from the side panel, with a way to undo it', (
        tester,
      ) async {
        useWideWindow(tester);
        final pressed = <String>[];
        await tester.pumpWidget(
          player(readyAt(), pressed: pressed, bookmarks: [named]),
        );
        await showBookmarks(tester);
        await fromMenu(tester, 'The twist', 'Delete');
        await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
        await tester.pumpAndSettle();
        expect(pressed, ['delete 1', 'restore 1']);
      });
    });
  });

  group('the keyboard shortcuts', () {
    /// Gives keyboard focus to the control around [finder], as tabbing to it would.
    Future<void> focus(WidgetTester tester, Finder finder) async {
      final node = Focus.of(tester.element(finder))..requestFocus();
      await tester.pump();
      expect(node.hasPrimaryFocus, isTrue);
    }

    testWidgets('space plays or pauses, with nothing clicked first', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(pressed, ['play']);
    });

    testWidgets('the arrow keys skip back and forward 30 seconds', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(pressed, ['skip -30', 'skip 30']);
    });

    testWidgets('the brackets step the speed down and up through the presets', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(speed: 1.25), pressed: pressed));
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      expect(pressed, ['speed 1.0', 'speed 1.5']);
    });

    testWidgets('the speed keys stop at the slowest and the fastest preset', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(speed: 0.75), pressed: pressed));
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      expect(pressed, isEmpty);

      await tester.pumpWidget(player(readyAt(speed: 2.0), pressed: pressed));
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      expect(pressed, isEmpty);
    });

    testWidgets('B adds a bookmark, and says so', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pumpAndSettle();

      expect(pressed, ['bookmark']);
      expect(find.text('Bookmark added'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'Add note'), findsOneWidget);
    });

    testWidgets('B held down adds one bookmark', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      await tester.pumpAndSettle();
      expect(pressed, ['bookmark']);
    });

    testWidgets('B is typed into a text field that has focus', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerShortcuts(
            state: readyAt(),
            onPlayPause: () => pressed.add('play'),
            onSkip: (_) => pressed.add('skip'),
            onSpeed: (_) => pressed.add('speed'),
            onAddBookmark: () => pressed.add('bookmark'),
            child: const Scaffold(body: TextField(autofocus: true)),
          ),
        ),
      );
      await tester.pump();

      // Left unhandled, so that the platform types it into the field.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyB), isFalse);
      expect(pressed, isEmpty);

      // And once the field lets go of focus, B adds a bookmark again.
      primaryFocus!.unfocus();
      await tester.pump();
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyB), isTrue);
      expect(pressed, ['bookmark']);
    });

    testWidgets("B typed into a bookmark's name adds no bookmark", (
      tester,
    ) async {
      useWideWindow(tester);
      final pressed = <String>[];
      await tester.pumpWidget(
        player(
          readyAt(),
          pressed: pressed,
          bookmarks: [bookmarkAt(1, 65000, title: 'The twist')],
        ),
      );
      await showBookmarks(tester);
      await fromMenu(tester, 'The twist', 'Rename');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(pressed, isEmpty);
    });

    testWidgets('space does not also press the button that has focus', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await focus(tester, find.byIcon(Icons.forward_30));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(pressed, ['play']);
    });

    testWidgets('space held down plays or pauses once', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await focus(tester, find.byIcon(Icons.forward_30));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(pressed, ['play']);
    });

    testWidgets('the keys still work once the focused control has gone', (
      tester,
    ) async {
      useWideWindow(tester);
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await toggleChapters(tester);
      await focus(tester, inList('Chapter One'));
      await toggleChapters(tester);
      expect(find.byType(ChapterList), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(pressed, ['play']);
    });

    testWidgets('the keys still work after a control lets go of focus', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(player(readyAt(), pressed: pressed));
      await focus(tester, find.byIcon(Icons.forward_30));
      // Unfocusing forgets what had focus before, so focus cannot simply return there.
      primaryFocus!.unfocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(pressed, ['play']);
    });

    testWidgets('the keys do nothing while no book is ready', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerShortcuts(
            state: null,
            onPlayPause: () => pressed.add('play'),
            onSkip: (_) => pressed.add('skip'),
            onSpeed: (_) => pressed.add('speed'),
            onAddBookmark: () => pressed.add('bookmark'),
            child: const Scaffold(),
          ),
        ),
      );
      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.bracketLeft,
        LogicalKeyboardKey.bracketRight,
        LogicalKeyboardKey.keyB,
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(pressed, isEmpty);
    });
  });
}
