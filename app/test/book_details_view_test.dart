import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/book_details_view.dart';
import 'package:kikuyomi/src/listened_commands.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart'
    show
        BookOverview,
        BookProgress,
        ChapterOverview,
        CoverFiles,
        MarkerOverview;
import 'package:kikuyomi_design_system/kikuyomi_design_system.dart';

/// A covers folder that holds nothing: the view only names a file in it.
final covers = CoverFiles(Directory('covers'));

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
  bool finished = false,
  bool inLibrary = true,
  List<ChapterOverview> chapters = threeChapters,
  List<MarkerOverview> markers = const [],
  String? cover,
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
  finished: finished,
  coverFileName: cover,
);

/// Eleven minutes in: a minute into Middle.
final elevenMinutesIn = BookProgress(
  chapterId: 11,
  chapterPositionMs: 60000,
  globalPositionMs: 660000,
  lastPlayedAt: DateTime.utc(2026, 9, 14),
);

/// The details of [overview], recording what was pressed in [pressed].
///
/// Marking the book finished reports chapters 11 and 12 as the ones it marked, as it would for
/// [threeChapters], where only Opening was listened.
Widget details(BookOverview overview, [List<String>? pressed]) => MaterialApp(
  home: Scaffold(
    body: BookDetailsView(
      book: overview,
      covers: covers,
      onRemove: () => pressed?.add('remove'),
      listenedCommands: ListenedCommands(
        markChapters: (chapterIds, listened) async {
          pressed?.add(
            'mark ${chapterIds.join(', ')} ${listened ? 'listened' : 'not listened'}',
          );
          return chapterIds;
        },
        markFinished: () async {
          pressed?.add('mark finished');
          return {11, 12};
        },
        markNotFinished: () async => pressed?.add('mark not finished'),
      ),
    ),
  ),
);

/// Tabs through the screen until the options button of chapter [title] has the keyboard's focus.
Future<void> tabTo(WidgetTester tester, String title) async {
  bool focused() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PopupMenuButton<bool>>()
          ?.tooltip ==
      'Options for $title';
  for (var i = 0; i < 20 && !focused(); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(focused(), isTrue, reason: 'the options for $title take focus');
}

/// Makes the window tall enough for the list to build every chapter below the cover and buttons.
void tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Finder iconIn(String title, IconData icon) => find.descendant(
  of: find.widgetWithText(ListTile, title),
  matching: find.byIcon(icon),
);

void main() {
  testWidgets('shows the title, credits, length and chapters', (tester) async {
    tallView(tester);
    await tester.pumpWidget(details(book()));

    expect(find.text('A Book'), findsOneWidget);
    expect(find.text('An Author, Second Author'), findsOneWidget);
    expect(find.text('A Narrator'), findsOneWidget);
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

  testWidgets('shows the cover beside what identifies the book', (
    tester,
  ) async {
    // Beside rather than above, so the title, the credits and the length are all on the first
    // screen of a phone instead of below a cover the width of the window.
    await tester.pumpWidget(details(book(cover: '1.jpg')));

    final cover = tester.widget<BookCover>(find.byType(BookCover));
    expect(cover.file!.path, covers.fileOf('1.jpg')!.path);
    expect(cover.semanticLabel, 'Cover of A Book');
    expect(
      tester.getTopRight(find.byType(BookCover)).dx,
      lessThanOrEqualTo(tester.getTopLeft(find.text('A Book')).dx),
    );
    expect(
      tester.getTopLeft(find.text('A Book')).dy,
      lessThan(tester.getBottomLeft(find.byType(BookCover)).dy),
      reason: 'the title sits alongside the cover, not under it',
    );
  });

  testWidgets('keeps the cover one size, whatever the window', (tester) async {
    // A fixed cover is what leaves the metadata a readable column beside it. Sizing it to the
    // window made that column collapse on a narrow one.
    tester.view.physicalSize = const Size(240, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(details(book()));

    expect(tester.getSize(find.byType(BookCover)).width, 120);
  });

  testWidgets('shows the time left on a started book', (tester) async {
    await tester.pumpWidget(details(book(progress: elevenMinutesIn)));

    expect(find.text('24:00 left'), findsOneWidget);
  });

  group('what the play button says', () {
    test('a book never started is started', () {
      expect(playButtonLabel(book()), 'Start');
      expect(playButtonFrom(book()), PlayFrom.savedPosition);
    });

    test('a book left part-way is resumed', () {
      final started = book(progress: elevenMinutesIn);
      expect(playButtonLabel(started), 'Resume');
      expect(playButtonFrom(started), PlayFrom.savedPosition);
    });

    test('a finished book is played again from the top', () {
      // Resuming it would drop the listener at the end, the one place they do not want.
      final done = book(progress: elevenMinutesIn, finished: true);
      expect(playButtonLabel(done), 'Play again');
      expect(playButtonFrom(done), PlayFrom.start);
    });
  });

  testWidgets('marks the chapters listened and the one being listened to', (
    tester,
  ) async {
    tallView(tester);
    await tester.pumpWidget(details(book(progress: elevenMinutesIn)));

    expect(iconIn('Opening', Icons.check), findsOneWidget);
    expect(iconIn('Middle', Icons.graphic_eq), findsOneWidget);
    expect(iconIn('End', Icons.check), findsNothing);
    expect(iconIn('End', Icons.graphic_eq), findsNothing);
  });

  testWidgets('lists embedded markers in place of the one chapter', (
    tester,
  ) async {
    tallView(tester);
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
    // A marker has no listened state of its own to set (§4.5).
    expect(find.byType(PopupMenuButton<bool>), findsNothing);
  });

  testWidgets('says a book marked finished is finished, started or not', (
    tester,
  ) async {
    await tester.pumpWidget(details(book(finished: true)));

    expect(find.text('Finished'), findsOneWidget);
    expect(find.text('Mark finished'), findsNothing);
  });

  group("a chapter's menu", () {
    testWidgets('marks a chapter not yet listened listened', (tester) async {
      tallView(tester);
      final pressed = <String>[];
      await tester.pumpWidget(details(book(), pressed));

      await tester.tap(find.byTooltip('Options for End'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as not listened'), findsNothing);
      await tester.tap(find.text('Mark as listened'));
      await tester.pumpAndSettle();

      expect(pressed, ['mark 12 listened']);
    });

    testWidgets('marks a listened chapter not listened', (tester) async {
      tallView(tester);
      final pressed = <String>[];
      await tester.pumpWidget(details(book(), pressed));

      await tester.tap(find.byTooltip('Options for Opening'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as not listened'));
      await tester.pumpAndSettle();

      expect(pressed, ['mark 10 not listened']);
    });

    testWidgets('is a button named for its chapter', (tester) async {
      tallView(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(details(book()));

      expect(
        tester.getSemantics(find.byTooltip('Options for End')),
        isSemantics(
          tooltip: 'Options for End',
          isButton: true,
          hasTapAction: true,
          isFocusable: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('is reached and used from the keyboard', (tester) async {
      tallView(tester);
      final pressed = <String>[];
      await tester.pumpWidget(details(book(), pressed));

      await tabTo(tester, 'End');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Mark as listened'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(pressed, ['mark 12 listened']);
    });
  });

  group('marking the whole book', () {
    testWidgets('marks it finished, and Undo marks back what it marked', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        details(book(progress: elevenMinutesIn), pressed),
      );

      await tester.tap(find.text('Mark finished'));
      await tester.pumpAndSettle();
      expect(pressed, ['mark finished']);
      expect(find.text('Marked as finished'), findsOneWidget);

      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await tester.pumpAndSettle();
      expect(pressed, ['mark finished', 'mark 11, 12 not listened']);
    });

    testWidgets('offers a finished book to be marked not finished', (
      tester,
    ) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        details(book(progress: elevenMinutesIn, finished: true), pressed),
      );

      expect(find.text('Mark finished'), findsNothing);
      await tester.tap(find.text('Finished'));
      await tester.pumpAndSettle();
      expect(pressed, ['mark not finished']);
    });

    testWidgets('is one cell of the strip with two faces', (tester) async {
      // A state as much as an action, which is what the strip is for: lit or not says at a glance
      // what a row of identical outlined buttons made you read to find out.
      await tester.pumpWidget(details(book()));
      expect(find.text('Mark finished'), findsOneWidget);
      expect(find.text('Finished'), findsNothing);

      await tester.pumpWidget(details(book(finished: true)));
      expect(find.text('Finished'), findsOneWidget);
      expect(find.text('Mark finished'), findsNothing);
    });
  });

  group('removing the book', () {
    testWidgets('asks first, and Cancel keeps it', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(details(book(), pressed));

      await tester.tap(find.text('In library'));
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

      await tester.tap(find.text('In library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(pressed, ['remove']);
    });

    testWidgets('is not offered for a book already out of the library', (
      tester,
    ) async {
      // The cell stays, saying what is true. Hiding it would move the ones beside it under the
      // listener's finger between one visit and the next.
      await tester.pumpWidget(details(book(inLibrary: false)));

      expect(find.text('In library'), findsNothing);
      expect(find.text('Add to library'), findsOneWidget);
    });
  });
}
