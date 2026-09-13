import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/format.dart';
import 'package:kikuyomi/src/player_view.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart'
    show ChapterPosition, MarkerEntry;
import 'package:kikuyomi_playback/kikuyomi_playback.dart'
    show
        PlayerReady,
        SleepAfter,
        SleepAtEndOfChapter,
        SleepTimerOff,
        SleepTimerRunning,
        SleepTimerState;

PlayerReady readyAt({
  bool playing = false,
  SleepTimerState sleepTimer = const SleepTimerOff(),
}) => PlayerReady(
  bookId: 1,
  position: const ChapterPosition(chapterId: 1, offsetMs: 65000),
  globalMs: 65000,
  totalMs: 3725000,
  entry: const MarkerEntry(title: 'Chapter Two', startMs: 60000, endMs: 120000),
  playing: playing,
  buffering: false,
  speed: 1.0,
  sleepTimer: sleepTimer,
  finished: false,
);

/// A player view for [state] that records what was pressed in [pressed].
Widget player(PlayerReady state, [List<String>? pressed]) {
  void press(String what) => pressed?.add(what);
  return MaterialApp(
    home: Scaffold(
      body: PlayerView(
        title: 'A Book',
        state: state,
        onPlayPause: () => press('play'),
        onSeek: (ms) => press('seek $ms'),
        onSkip: (by) => press('skip ${by.inSeconds}'),
        onPreviousChapter: () => press('previous'),
        onNextChapter: () => press('next'),
        onSpeed: (speed) => press('speed $speed'),
        onSleepTimer: (target) => press(switch (target) {
          SleepAfter(:final duration) => 'sleep ${duration.inMinutes}',
          SleepAtEndOfChapter() => 'sleep at end of chapter',
        }),
        onCancelSleepTimer: () => press('sleep off'),
      ),
    ),
  );
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
    await tester.pumpWidget(player(readyAt(), pressed));
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
      await tester.pumpWidget(player(readyAt(), pressed));
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
          pressed,
        ),
      );
      expect(find.text('14:05'), findsOneWidget);
      await choose(tester, 'Off');
      expect(pressed, ['sleep off']);
    });
  });
}
