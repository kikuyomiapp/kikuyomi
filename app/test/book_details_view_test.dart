import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/book_details_view.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart'
    show BookOverview, BookProgress, ChapterOverview, MarkerOverview;

const threeChapters = [
  ChapterOverview(
    chapterId: 10,
    title: 'Opening',
    durationMs: 600000,
    listened: true,
    current: false,
  ),
  ChapterOverview(
    chapterId: 11,
    title: 'Middle',
    durationMs: 1200000,
    listened: false,
    current: true,
  ),
  ChapterOverview(
    chapterId: 12,
    title: 'End',
    durationMs: 300000,
    listened: false,
    current: false,
  ),
];

BookOverview book({
  BookProgress? progress,
  bool inLibrary = true,
  List<ChapterOverview> chapters = threeChapters,
  List<MarkerOverview> markers = const [],
}) => BookOverview(
  bookId: 1,
  title: 'A Book',
  authors: const ['An Author', 'Second Author'],
  narrators: const ['A Narrator'],
  totalDurationMs: 2100000,
  inLibrary: inLibrary,
  chapters: chapters,
  markers: markers,
  progress: progress,
  coverFileName: null,
);

/// Eleven minutes in: a minute into Middle.
BookProgress elevenMinutesIn({bool finished = false}) => BookProgress(
  chapterId: 11,
  chapterPositionMs: 60000,
  globalPositionMs: 660000,
  lastPlayedAt: DateTime.utc(2026, 9, 14),
  finished: finished,
);

/// The details of [overview], recording what was pressed in [pressed].
Widget details(BookOverview overview, [List<String>? pressed]) => MaterialApp(
  home: Scaffold(
    body: BookDetailsView(
      book: overview,
      onPlay: (from) => pressed?.add('play from ${from.name}'),
      onRemove: () => pressed?.add('remove'),
    ),
  ),
);

Finder iconIn(String title, IconData icon) => find.descendant(
  of: find.widgetWithText(ListTile, title),
  matching: find.byIcon(icon),
);

void main() {
  testWidgets('shows the title, credits, length and chapters', (tester) async {
    await tester.pumpWidget(details(book()));

    expect(find.text('A Book'), findsOneWidget);
    expect(find.text('By An Author, Second Author'), findsOneWidget);
    expect(find.text('Read by A Narrator'), findsOneWidget);
    expect(find.text('35:00'), findsOneWidget);
    for (final (title, length) in [
      ('Opening', '10:00'),
      ('Middle', '20:00'),
      ('End', '5:00'),
    ]) {
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, title),
          matching: find.text(length),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('offers Play for a book never started', (tester) async {
    final pressed = <String>[];
    await tester.pumpWidget(details(book(), pressed));
    await tester.tap(find.text('Play'));
    expect(pressed, ['play from savedPosition']);
  });

  testWidgets('offers Resume, with the time left, for a started book', (
    tester,
  ) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      details(book(progress: elevenMinutesIn()), pressed),
    );

    expect(find.text('24:00 left'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    expect(pressed, ['play from savedPosition']);
  });

  testWidgets('offers to play a finished book again from the start', (
    tester,
  ) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      details(book(progress: elevenMinutesIn(finished: true)), pressed),
    );

    expect(find.text('Finished'), findsOneWidget);
    await tester.tap(find.text('Play again'));
    expect(pressed, ['play from start']);
  });

  testWidgets('marks the chapters listened and the one being listened to', (
    tester,
  ) async {
    await tester.pumpWidget(details(book(progress: elevenMinutesIn())));

    expect(iconIn('Opening', Icons.check), findsOneWidget);
    expect(iconIn('Middle', Icons.graphic_eq), findsOneWidget);
    expect(iconIn('End', Icons.check), findsNothing);
    expect(iconIn('End', Icons.graphic_eq), findsNothing);
  });

  testWidgets('lists embedded markers in place of the one chapter', (
    tester,
  ) async {
    await tester.pumpWidget(
      details(
        book(
          chapters: const [
            ChapterOverview(
              chapterId: 10,
              title: 'A Book',
              durationMs: 2100000,
              listened: false,
              current: false,
            ),
          ],
          markers: const [
            MarkerOverview(
              title: 'Chapter One',
              startMs: 0,
              endMs: 900000,
              listened: true,
              current: false,
            ),
            MarkerOverview(
              title: 'Chapter Two',
              startMs: 900000,
              endMs: 2100000,
              listened: false,
              current: true,
            ),
          ],
        ),
      ),
    );

    expect(find.widgetWithText(ListTile, 'A Book'), findsNothing);
    expect(iconIn('Chapter One', Icons.check), findsOneWidget);
    expect(iconIn('Chapter Two', Icons.graphic_eq), findsOneWidget);
    expect(find.text('20:00'), findsOneWidget);
  });

  group('removing the book', () {
    testWidgets('asks first, and Cancel keeps it', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(details(book(), pressed));

      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from library?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from library?'), findsNothing);
      expect(pressed, isEmpty);
    });

    testWidgets('happens once confirmed', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(details(book(), pressed));

      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(pressed, ['remove']);
    });

    testWidgets('is not offered for a book already out of the library', (
      tester,
    ) async {
      await tester.pumpWidget(details(book(inLibrary: false)));
      expect(find.text('Remove from library'), findsNothing);
    });
  });
}
