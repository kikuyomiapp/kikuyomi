import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/source_book_view.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

BookDetails moby({
  String? description = 'Call me Ishmael.\n\nThere is a whale.',
  List<String> narrators = const ['Stewart Wills', 'Kristin LeMoine'],
  Uri? webUrl,
}) => BookDetails(
  key: '753',
  title: 'Moby Dick, or the Whale',
  authors: const ['Herman Melville'],
  narrators: narrators,
  description: description,
  genres: const ['Nautical & Marine Fiction'],
  language: 'en',
  publisher: 'LibriVox',
  publishedDate: '1851',
  totalDurationMs: 3600000 * 24,
  status: BookStatus.complete,
  webUrl: webUrl,
);

final chapters = [
  const ChapterInfo(key: 's1', title: 'Loomings', durationMs: 1753000),
  const ChapterInfo(key: 's2', title: 'The Carpet-Bag', durationMs: 900000),
];

Widget view({
  BookDetails? details,
  List<ChapterInfo>? chapters,
  bool inLibrary = false,
  bool adding = false,
  VoidCallback? onAdd,
  VoidCallback? onOpenAtSource,
}) => MaterialApp(
  home: Scaffold(
    body: SourceBookView(
      details: details ?? moby(),
      chapters: chapters ?? [],
      inLibrary: inLibrary,
      adding: adding,
      onAdd: onAdd ?? () {},
      onOpenAtSource: onOpenAtSource,
    ),
  ),
);

void main() {
  testWidgets('shows what the source says about the book', (tester) async {
    await tester.pumpWidget(view(chapters: chapters));

    expect(find.text('Moby Dick, or the Whale'), findsOneWidget);
    // The credits are one rich line, "By <names>", so they are found inside it.
    expect(
      find.textContaining('Herman Melville', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Stewart Wills, Kristin LeMoine', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Call me Ishmael.\n\nThere is a whale.'), findsOneWidget);
    expect(find.text('Nautical & Marine Fiction'), findsOneWidget);
    expect(find.textContaining('1851'), findsOneWidget);
    expect(find.textContaining('LibriVox'), findsOneWidget);
  });

  testWidgets('lists the chapters with their lengths', (tester) async {
    await tester.pumpWidget(view(chapters: chapters));

    expect(find.text('Chapters (2)'), findsOneWidget);
    expect(find.text('Loomings'), findsOneWidget);
    expect(find.text('29:13'), findsOneWidget);
    expect(find.text('The Carpet-Bag'), findsOneWidget);
  });

  testWidgets('says so when the source lists no chapters', (tester) async {
    await tester.pumpWidget(view());

    expect(
      find.text('This source lists no chapters for this book.'),
      findsOneWidget,
    );
  });

  testWidgets('a book with no description still shows everything else', (
    tester,
  ) async {
    await tester.pumpWidget(view(details: moby(description: null)));

    expect(find.text('About'), findsNothing);
    expect(find.text('Moby Dick, or the Whale'), findsOneWidget);
  });

  testWidgets('adding it says so and calls back once', (tester) async {
    var added = 0;
    await tester.pumpWidget(view(chapters: chapters, onAdd: () => added++));

    expect(find.text('Add to library'), findsOneWidget);
    await tester.tap(find.text('Add to library'));

    expect(added, 1);
  });

  testWidgets('while it is being added the button says so and waits', (
    tester,
  ) async {
    var added = 0;
    await tester.pumpWidget(view(adding: true, onAdd: () => added++));

    expect(find.text('Adding…'), findsOneWidget);
    await tester.tap(find.text('Adding…'));

    expect(added, 0);
  });

  testWidgets('once it is in the library the button opens it', (tester) async {
    await tester.pumpWidget(view(inLibrary: true));

    expect(find.text('Open in library'), findsOneWidget);
  });

  testWidgets('a book with a page at the source offers to open it', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      view(
        details: moby(webUrl: Uri.parse('https://librivox.org/moby-dick/')),
        onOpenAtSource: () => opened++,
      ),
    );

    await tester.tap(find.byTooltip('Open at the source'));

    expect(opened, 1);
  });

  testWidgets('a book with no page at the source offers nothing', (
    tester,
  ) async {
    await tester.pumpWidget(view());

    expect(find.byTooltip('Open at the source'), findsNothing);
  });
}
