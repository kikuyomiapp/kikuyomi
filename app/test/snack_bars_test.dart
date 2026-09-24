// How long a snack bar stays, and whether it has to be dismissed by hand.
//
// The bug these guard: a snack bar carrying an action stays on screen until the action is taken, so
// "Added … to the library" had to be swiped away. And a handful of messages in a row queued, each
// waiting out the one before it.
//
// On timing: a snack bar's dismissal timer starts once its entrance animation has finished, so every
// test settles the entrance before advancing the clock, and settles again for the exit.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/snack_bars.dart';

/// A screen with a button that shows a snack bar, so the real ScaffoldMessenger is involved.
Widget harness({
  required void Function(BuildContext context, ScaffoldMessengerState messenger)
  show,
  bool accessibleNavigation = false,
}) => MaterialApp(
  theme: ThemeData(snackBarTheme: kikuyomiSnackBarTheme),
  home: Builder(
    builder: (context) => MediaQuery(
      // The app's own media query, with only the one field this test cares about changed, so the
      // screen still has a size to lay out in.
      data: MediaQuery.of(context)
          .copyWith(accessibleNavigation: accessibleNavigation),
      child: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => show(context, ScaffoldMessenger.of(context)),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  /// Taps the button and lets the snack bar finish arriving, which is when its timer starts.
  Future<void> showIt(WidgetTester tester) async {
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  /// Advances past [stay] and lets the snack bar finish leaving.
  Future<void> waitOut(WidgetTester tester, Duration stay) async {
    await tester.pump(stay);
    await tester.pumpAndSettle();
  }

  group('a notice offering an action', () {
    Widget offering({bool accessibleNavigation = false}) => harness(
      accessibleNavigation: accessibleNavigation,
      show: (context, messenger) => offerInSnackBar(
        context,
        messenger,
        message: 'Added A Book to the library',
        action: 'Open',
        onPressed: () {},
      ),
    );

    testWidgets('goes on its own, without being dismissed', (tester) async {
      await tester.pumpWidget(offering());
      await showIt(tester);

      expect(find.text('Added A Book to the library'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);

      // Flutter would keep a snack bar with an action up indefinitely, which is the behaviour this
      // replaces: it had to be swiped away by hand.
      await waitOut(tester, snackBarOffer);

      expect(find.text('Added A Book to the library'), findsNothing);
    });

    testWidgets('stays for someone who needs longer to reach it', (
      tester,
    ) async {
      await tester.pumpWidget(offering(accessibleNavigation: true));
      await showIt(tester);

      await tester.pump(snackBarOffer);
      await tester.pump(const Duration(seconds: 10));

      expect(
        find.text('Added A Book to the library'),
        findsOneWidget,
        reason:
            'a button that vanishes before switch access reaches it is no '
            'button at all',
      );
      // And it can be closed, rather than only waited out.
      expect(find.byType(IconButton), findsOneWidget);
    });
  });

  group('a plain notice', () {
    testWidgets('goes after a couple of seconds', (tester) async {
      await tester.pumpWidget(
        harness(
          show: (context, messenger) => tellInSnackBar(messenger, 'Done'),
        ),
      );
      await showIt(tester);

      expect(find.text('Done'), findsOneWidget);

      await waitOut(tester, snackBarNotice);

      expect(find.text('Done'), findsNothing);
    });

    testWidgets('replaces the one before it rather than queueing', (
      tester,
    ) async {
      var count = 0;
      await tester.pumpWidget(
        harness(
          show: (context, messenger) =>
              tellInSnackBar(messenger, 'Message ${++count}'),
        ),
      );

      await showIt(tester);
      await showIt(tester);

      expect(find.text('Message 1'), findsNothing);
      expect(find.text('Message 2'), findsOneWidget);

      // The second is the only one left to wait out. A queue would bring the first back here.
      await waitOut(tester, snackBarNotice);
      expect(find.textContaining('Message'), findsNothing);
    });
  });

  test('a notice is brief enough to stay out of the way', () {
    expect(snackBarNotice.inSeconds, lessThanOrEqualTo(2));
    expect(
      snackBarOffer,
      greaterThan(snackBarNotice),
      reason: 'an action needs a beat longer than a notice to be reachable',
    );
    expect(snackBarOffer.inSeconds, lessThanOrEqualTo(3));
  });
}
