import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/home_view.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart'
    show BookRow, ContinueListeningBook;

final added = DateTime.utc(2026, 9, 14);

BookRow inLibrary(int id, String title) => BookRow(
  id: id,
  sourceId: 1,
  key: 'book-$id',
  title: title,
  genres: const [],
  totalDurationMs: 3725000,
  inLibrary: true,
  detailsFetched: true,
  userOverrides: const {},
  createdAt: added,
  updatedAt: added,
);

ContinueListeningBook started(
  int id,
  String title, {
  String chapterTitle = 'Chapter Two',
}) => ContinueListeningBook(
  bookId: id,
  title: title,
  author: 'An Author',
  totalDurationMs: 3725000,
  globalPositionMs: 65000,
  chapterTitle: chapterTitle,
  lastPlayedAt: added,
);

/// A home showing [continueListening] and [library], recording what was tapped in [tapped].
Widget home({
  List<ContinueListeningBook> continueListening = const [],
  List<BookRow> library = const [],
  List<String>? tapped,
}) => MaterialApp(
  home: Scaffold(
    body: HomeView(
      continueListening: continueListening,
      library: library,
      emptyMessage: 'No books yet.',
      onResume: (bookId) => tapped?.add('resume $bookId'),
      onShowDetails: (bookId) => tapped?.add('details $bookId'),
    ),
  ),
);

void main() {
  testWidgets('shows the books to continue above the library', (tester) async {
    await tester.pumpWidget(
      home(
        continueListening: [started(2, 'Second Book')],
        library: [inLibrary(1, 'First Book'), inLibrary(2, 'Second Book')],
      ),
    );

    expect(find.text('An Author · Chapter Two'), findsOneWidget);
    expect(find.text('1:01:00 left'), findsOneWidget);
    expect(find.text('First Book'), findsOneWidget);
    expect(find.text('Second Book'), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('Continue listening')).dy,
      lessThan(tester.getTopLeft(find.text('Library')).dy),
    );
  });

  testWidgets(
    'a book to continue resumes, and a library book shows its details',
    (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(
        home(
          continueListening: [started(2, 'Second Book')],
          library: [inLibrary(1, 'First Book'), inLibrary(2, 'Second Book')],
          tapped: tapped,
        ),
      );

      await tester.tap(find.text('An Author · Chapter Two'));
      await tester.tap(find.text('First Book'));
      expect(tapped, ['resume 2', 'details 1']);
    },
  );

  testWidgets('has no Continue listening before a book is started', (
    tester,
  ) async {
    await tester.pumpWidget(home(library: [inLibrary(1, 'First Book')]));
    expect(find.text('Continue listening'), findsNothing);
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets('says how to begin while there are no books', (tester) async {
    await tester.pumpWidget(home());
    expect(find.text('No books yet.'), findsOneWidget);
    expect(find.text('Library'), findsNothing);
  });

  testWidgets('does not repeat a chapter title that is the book title', (
    tester,
  ) async {
    await tester.pumpWidget(
      home(
        continueListening: [started(1, 'A Book', chapterTitle: 'A Book')],
        library: [inLibrary(1, 'A Book')],
      ),
    );
    expect(find.text('An Author'), findsOneWidget);
  });

  group('the books to continue', () {
    Future<void> showTwo(WidgetTester tester, Size window) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        home(
          continueListening: [started(1, 'One'), started(2, 'Two')],
          library: [inLibrary(3, 'Three')],
        ),
      );
    }

    testWidgets('sit side by side on a wide window', (tester) async {
      await showTwo(tester, const Size(1280, 800));
      expect(
        tester.getTopLeft(find.text('Two')).dy,
        tester.getTopLeft(find.text('One')).dy,
      );
    });

    testWidgets('stack one above the other on a phone', (tester) async {
      await showTwo(tester, const Size(400, 800));
      expect(
        tester.getTopLeft(find.text('Two')).dy,
        greaterThan(tester.getTopLeft(find.text('One')).dy),
      );
    });
  });
}
