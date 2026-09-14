import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/chapter_list.dart';
import 'package:kikuyomi/src/format.dart';
import 'package:kikuyomi/src/player_shortcuts.dart';
import 'package:kikuyomi/src/player_view.dart';
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

/// A player view for [state], with its keyboard shortcuts around it as the player screen has them,
/// that records what was pressed in [pressed].
Widget player(PlayerReady state, {List<String>? pressed}) {
  void press(String what) => pressed?.add(what);
  void playPause() => press('play');
  void skip(Duration by) => press('skip ${by.inSeconds}');
  void speed(double to) => press('speed $to');
  return MaterialApp(
    home: PlayerShortcuts(
      state: state,
      onPlayPause: playPause,
      onSkip: skip,
      onSpeed: speed,
      child: Scaffold(
        body: PlayerView(
          title: 'A Book',
          state: state,
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
  );
}

/// Makes the test window as wide as a desktop one, which the chapter side panel needs.
void useWideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> toggleChapters(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Chapters'));
  await tester.pumpAndSettle();
}

/// [text] in the chapter list, rather than on the player under it.
Finder inList(String text) =>
    find.descendant(of: find.byType(ChapterList), matching: find.text(text));

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
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(pressed, isEmpty);
    });
  });
}
