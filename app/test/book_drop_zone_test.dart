import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/book_drop_zone.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart'
    show FileDropTarget;

final overlay = find.text('Drop audiobooks to add them');
final library = find.text('The library');

/// A library screen inside a drop zone, recording what is dropped on it in [dropped].
Widget zone({bool enabled = true, List<List<String>>? dropped}) => MaterialApp(
  home: BookDropZone(
    enabled: enabled,
    onDropped: (paths) => dropped?.add(paths),
    child: const Scaffold(body: Center(child: Text('The library'))),
  ),
);

/// The drop target around the screen. Its callbacks stand in for the platform's drags, so no test
/// here depends on the plugin.
FileDropTarget target(WidgetTester tester) => tester.widget<FileDropTarget>(
  find.byType(FileDropTarget, skipOffstage: false),
);

NavigatorState navigator(WidgetTester tester) =>
    tester.state<NavigatorState>(find.byType(Navigator));

Future<void> openAnotherScreen(WidgetTester tester) async {
  unawaited(
    navigator(tester).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('The player')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('covers the whole screen while something is dragged over it', (
    tester,
  ) async {
    await tester.pumpWidget(zone());
    expect(overlay, findsNothing);

    target(tester).onDragEntered();
    await tester.pump();
    expect(overlay, findsOneWidget);
    expect(find.byIcon(Icons.library_add_outlined), findsOneWidget);
    final cover = find.ancestor(of: overlay, matching: find.byType(Material));
    expect(tester.getRect(cover.first), tester.getRect(find.byType(Scaffold)));

    target(tester).onDragExited();
    await tester.pump();
    expect(overlay, findsNothing);
    expect(library, findsOneWidget);
  });

  testWidgets('passes on the paths dropped on it', (tester) async {
    final dropped = <List<String>>[];
    await tester.pumpWidget(zone(dropped: dropped));

    target(tester)
      ..onDragEntered()
      ..onDragExited()
      ..onDropped([r'C:\Books\One.m4b', r'C:\Books\Two']);
    await tester.pump();
    expect(dropped, [
      [r'C:\Books\One.m4b', r'C:\Books\Two'],
    ]);
    expect(overlay, findsNothing);
  });

  testWidgets('takes drops only while its screen is the one shown', (
    tester,
  ) async {
    await tester.pumpWidget(zone());
    expect(target(tester).enabled, isTrue);

    await openAnotherScreen(tester);
    expect(target(tester).enabled, isFalse);

    navigator(tester).pop();
    await tester.pumpAndSettle();
    expect(target(tester).enabled, isTrue);
  });

  testWidgets('forgets a drag when another screen opens over it', (
    tester,
  ) async {
    await tester.pumpWidget(zone());
    target(tester).onDragEntered();
    await tester.pump();

    await openAnotherScreen(tester);
    navigator(tester).pop();
    await tester.pumpAndSettle();
    expect(overlay, findsNothing);
    expect(library, findsOneWidget);
  });

  testWidgets('takes no drops on a device that does not accept them', (
    tester,
  ) async {
    await tester.pumpWidget(zone(enabled: false));
    expect(target(tester).enabled, isFalse);
  });
}
