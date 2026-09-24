// The Extensions screen's own wiring, without a database, a folder or an engine: what it says about an
// extension, what it offers to do with one, and what it refuses to offer.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/extensions_view.dart';
import 'package:kikuyomi/src/sources/extension_library.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

final _at = DateTime.utc(2026, 9, 23, 9);

ExtensionSummary summary({
  String id = 'org.example.librivox',
  String name = 'LibriVox',
  String version = '1.4.0',
  ExtensionStatus status = ExtensionStatus.untrusted,
  ExtensionOrigin origin = ExtensionOrigin.folder,
  String? originHandle = r'G:\work\librivox',
  String? originName = r'G:\work\librivox',
  bool isRunnable = true,
}) => ExtensionSummary(
  row: ExtensionRow(
    id: id,
    name: name,
    version: version,
    versionCode: 14,
    apiVersion: '1.0',
    status: status,
    origin: origin,
    originHandle: originHandle,
    originName: originName,
    installPath: origin == ExtensionOrigin.bundled ? null : '$id/14',
    installedAt: _at,
  ),
  isRunnable: isRunnable,
);

final bundled = summary(
  id: 'org.kikuyomi.librivox',
  status: ExtensionStatus.active,
  origin: ExtensionOrigin.bundled,
  originHandle: null,
  originName: null,
);

void main() {
  late List<String> reloaded;
  late List<String> removed;
  late List<String?> consoles;
  late int pickerAsked;
  late int dropFolderAsked;

  setUp(() {
    reloaded = [];
    removed = [];
    consoles = [];
    pickerAsked = 0;
    dropFolderAsked = 0;
  });

  Future<void> show(
    WidgetTester tester, {
    List<ExtensionSummary> extensions = const [],
    Map<String, int> problems = const {},
    bool canChooseFolder = true,
    String? dropFolderName,
    String? busyWith,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ExtensionsView(
          extensions: extensions,
          problems: problems,
          canChooseFolder: canChooseFolder,
          dropFolderName: dropFolderName,
          busyWith: busyWith,
          onInstallFromFolder: () => pickerAsked++,
          onInstallFromDropFolder: () => dropFolderAsked++,
          onReload: (e) => reloaded.add(e.id),
          onRemove: (e) => removed.add(e.id),
          onOpenConsole: consoles.add,
        ),
      ),
    ),
  );

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  group('what it says about an extension', () {
    testWidgets('its name, version and id', (tester) async {
      await show(tester, extensions: [summary()]);

      expect(find.textContaining('LibriVox'), findsWidgets);
      expect(find.textContaining('1.4.0'), findsOneWidget);
      expect(find.text('org.example.librivox'), findsOneWidget);
    });

    testWidgets('that a folder install was not verified (§3.8)', (
      tester,
    ) async {
      await show(tester, extensions: [summary()]);

      expect(find.text('Unverified'), findsOneWidget);
    });

    testWidgets('that the one inside the app ships with it', (tester) async {
      await show(tester, extensions: [bundled]);

      expect(find.text('Ships with Kikuyomi'), findsOneWidget);
      expect(find.text('Unverified'), findsNothing);
    });

    testWidgets('where it came from', (tester) async {
      await show(tester, extensions: [summary()]);

      expect(find.text(r'G:\work\librivox'), findsOneWidget);
    });

    testWidgets('how many failures it has produced', (tester) async {
      await show(
        tester,
        extensions: [summary()],
        problems: {'org.example.librivox': 3},
      );

      expect(find.text('3 problems'), findsOneWidget);
    });

    testWidgets('that one failure is one problem, not 1 problems', (
      tester,
    ) async {
      await show(
        tester,
        extensions: [summary()],
        problems: {'org.example.librivox': 1},
      );

      expect(find.text('1 problem'), findsOneWidget);
    });

    testWidgets('that its files could not be read this time', (tester) async {
      await show(tester, extensions: [summary(isRunnable: false)]);

      expect(find.text('Could not be read'), findsOneWidget);
    });
  });

  group('what it offers', () {
    testWidgets('installing from a folder, where one can be picked', (
      tester,
    ) async {
      await show(tester);
      await tester.tap(find.text('Install from a folder'));

      expect(pickerAsked, 1);
    });

    testWidgets('the app\u2019s own folder where that is the way in', (
      tester,
    ) async {
      // iOS: no folder outside the app can be kept, so the Files app is the door.
      await show(tester, canChooseFolder: false, dropFolderName: 'Extensions');

      expect(find.text('Install from a folder'), findsNothing);
      await tester.tap(find.text('Install from Extensions'));
      expect(dropFolderAsked, 1);
    });

    testWidgets('a word about it when neither way is open', (tester) async {
      await show(tester, canChooseFolder: false);

      expect(
        find.text('This device cannot install an extension from a folder yet.'),
        findsOneWidget,
      );
    });

    testWidgets('reloading a folder install, and removing it', (tester) async {
      await show(tester, extensions: [summary()]);
      await openMenu(tester);

      await tester.tap(find.text('Reload from its folder'));
      await tester.pumpAndSettle();
      await openMenu(tester);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(reloaded, ['org.example.librivox']);
      expect(removed, ['org.example.librivox']);
    });

    testWidgets('neither for the extension inside the app', (tester) async {
      await show(tester, extensions: [bundled]);
      await openMenu(tester);

      expect(find.text('Remove'), findsNothing);
      expect(find.text('Reload from its folder'), findsNothing);
      expect(find.text('What it logged'), findsOneWidget);
    });

    testWidgets('what one extension logged, by tapping it', (tester) async {
      await show(tester, extensions: [summary()]);
      await tester.tap(find.text('org.example.librivox'));

      expect(consoles, ['org.example.librivox']);
    });
  });

  group('while something is under way', () {
    testWidgets('installing again is not offered', (tester) async {
      await show(tester, busyWith: '');

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });

    testWidgets('the extension being worked on says so', (tester) async {
      await show(
        tester,
        extensions: [summary()],
        busyWith: 'org.example.librivox',
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('removing one', () {
    testWidgets('says the books stay, and does nothing until confirmed', (
      tester,
    ) async {
      late bool answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    answer = await confirmRemoveExtension(context, summary()),
                child: const Text('remove'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('remove'));
      await tester.pumpAndSettle();
      expect(find.text('Remove LibriVox?'), findsOneWidget);
      expect(find.textContaining('stay in your library'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answer, isFalse);

      await tester.tap(find.text('remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });
  });
}
