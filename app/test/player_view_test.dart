import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/format.dart';
import 'package:kikuyomi/src/player_view.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart'
    show ChapterPosition, MarkerEntry;
import 'package:kikuyomi_playback/kikuyomi_playback.dart'
    show PlayerReady, SleepTimerOff;

PlayerReady readyAt({bool playing = false}) => PlayerReady(
  bookId: 1,
  position: const ChapterPosition(chapterId: 1, offsetMs: 65000),
  globalMs: 65000,
  totalMs: 3725000,
  entry: const MarkerEntry(title: 'Chapter Two', startMs: 60000, endMs: 120000),
  playing: playing,
  buffering: false,
  speed: 1.0,
  sleepTimer: const SleepTimerOff(),
  finished: false,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('clock formatting', () {
    expect(formatClock(0), '0:00');
    expect(formatClock(65000), '1:05');
    expect(formatClock(3725000), '1:02:05');
    expect(formatClock(-5), '0:00');
  });

  testWidgets('shows the book, the chapter and the time', (tester) async {
    await tester.pumpWidget(
      host(
        PlayerView(
          title: 'A Book',
          state: readyAt(),
          onPlayPause: () {},
          onSeek: (_) {},
          onSkip: (_) {},
          onPreviousChapter: () {},
          onNextChapter: () {},
          onSpeed: (_) {},
        ),
      ),
    );
    expect(find.text('A Book'), findsOneWidget);
    expect(find.text('Chapter Two'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.text('-1:01:00'), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
  });

  testWidgets('offers pause while playing', (tester) async {
    await tester.pumpWidget(
      host(
        PlayerView(
          title: 'A Book',
          state: readyAt(playing: true),
          onPlayPause: () {},
          onSeek: (_) {},
          onSkip: (_) {},
          onPreviousChapter: () {},
          onNextChapter: () {},
          onSpeed: (_) {},
        ),
      ),
    );
    expect(find.byTooltip('Pause'), findsOneWidget);
  });

  testWidgets('the transport buttons report what was pressed', (tester) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      host(
        PlayerView(
          title: 'A Book',
          state: readyAt(),
          onPlayPause: () => pressed.add('play'),
          onSeek: (ms) => pressed.add('seek $ms'),
          onSkip: (by) => pressed.add('skip ${by.inSeconds}'),
          onPreviousChapter: () => pressed.add('previous'),
          onNextChapter: () => pressed.add('next'),
          onSpeed: (speed) => pressed.add('speed $speed'),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Play'));
    await tester.tap(find.byTooltip('Back 30 seconds'));
    await tester.tap(find.byTooltip('Forward 30 seconds'));
    await tester.tap(find.byTooltip('Previous chapter'));
    await tester.tap(find.byTooltip('Next chapter'));
    expect(pressed, ['play', 'skip -30', 'skip 30', 'previous', 'next']);
  });
}
