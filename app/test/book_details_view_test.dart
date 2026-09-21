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
      onPlay: (from) => pressed?.add('play from ${from.name}'),
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

  testWidgets('shows the cover above the title', (tester) async {
    await tester.pumpWidget(details(book(cover: '1.jpg')));

    final cover = tester.widget<BookCover>(find.byType(BookCover));
    expect(cover.file!.path, covers.fileOf('1.jpg')!.path);
    expect(cover.semanticLabel, 'Cover of A Book');
    expect(tester.getSize(find.byType(BookCover)), const Size(240, 240));
    expect(
      tester.getBottomLeft(find.byType(BookCover)).dy,
      lessThan(tester.getTopLeft(find.text('A Book')).dy),
    );
  });

  testWidgets('narrows the cover to fit a narrow window', (tester) async {
    tester.view.physicalSize = const Size(240, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(details(book()));

    expect(tester.getSize(find.byType(BookCover)), const Size(208, 208));
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
    await tester.pumpWidget(details(book(progress: elevenMinutesIn), pressed));

    expect(find.text('24:00 left'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    expect(pressed, ['play from savedPosition']);
  });

  testWidgets('offers to play a finished book again from the start', (
    tester,
  ) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      details(book(progress: elevenMinutesIn, finished: true), pressed),
    );

    expect(find.text('Finished'), findsOneWidget);
    await tester.tap(find.text('Play again'));
    expect(pressed, ['play from start']);
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
    final pressed = <String>[];
    await tester.pumpWidget(details(book(finished: true), pressed));

    expect(find.text('Finished'), findsOneWidget);
    await tester.tap(find.text('Play again'));
    expect(pressed, ['play from start']);
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

      await tester.tap(find.text('Mark as finished'));
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

      expect(find.text('Mark as finished'), findsNothing);
      await tester.tap(find.text('Mark as not finished'));
      await tester.pumpAndSettle();
      expect(pressed, ['mark not finished']);
    });

    testWidgets('is a pair of buttons, one for each way', (tester) async {
      await tester.pumpWidget(details(book()));
      expect(
        find.widgetWithText(OutlinedButton, 'Mark as finished'),
        findsOneWidget,
      );

      await tester.pumpWidget(details(book(finished: true)));
      expect(
        find.widgetWithText(OutlinedButton, 'Mark as not finished'),
        findsOneWidget,
      );
    });
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
