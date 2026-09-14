import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kikuyomi/src/routes.dart';

/// The paths of the routes [location] leads through, from the root, as the app's router matches it.
/// Empty when no route matches.
List<String> pathsTo(String location) {
  final router = createRouter();
  addTearDown(router.dispose);
  final found = router.configuration.findMatch(Uri.parse(location));
  return [for (final match in found.matches) (match.route as GoRoute).path];
}

void main() {
  test('routes put their arguments in their locations', () {
    expect(const HomeRoute().location, '/');
    expect(const BookRoute(bookId: 7).location, '/book/7');
    expect(const PlayerRoute().location, '/player');
  });

  testWidgets("a book's location leads to its details, above the library", (
    tester,
  ) async {
    expect(pathsTo(const BookRoute(bookId: 7).location), [
      '/',
      r'book/:bookId(\d+)',
    ]);
  });

  testWidgets('the player opens above the library', (tester) async {
    expect(pathsTo(const PlayerRoute().location), ['/', 'player']);
  });

  testWidgets('a book id that is not a number leads nowhere', (tester) async {
    expect(pathsTo('/book/seven'), isEmpty);
  });

  testWidgets('a location no route matches offers the way to the library', (
    tester,
  ) async {
    final router = createRouter(initialLocation: '/nowhere');
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('There is nothing at /nowhere'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Go to the library'),
      findsOneWidget,
    );
  });
}
