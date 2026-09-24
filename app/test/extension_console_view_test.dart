// The console (§3.11): an extension's own words, the app's words about it, and never one dressed as
// the other.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/extension_console_view.dart';
import 'package:kikuyomi/src/sources/extension_console.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';

final _at = DateTime.utc(2026, 9, 23, 9, 41, 12);

ExtensionLogLine line(
  String text, {
  String extensionId = 'org.example.librivox',
  ExtensionLogLevel level = ExtensionLogLevel.info,
  bool fromTheApp = false,
  Duration after = Duration.zero,
}) => ExtensionLogLine(
  extensionId: extensionId,
  level: level,
  text: text,
  at: _at.add(after),
  fromTheApp: fromTheApp,
);

void main() {
  Future<void> show(
    WidgetTester tester,
    List<ExtensionLogLine> lines, {
    String? only,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ExtensionConsoleView(lines: lines, only: only),
      ),
    ),
  );

  testWidgets('says so when an extension has logged nothing', (tester) async {
    await show(tester, const []);

    expect(find.textContaining('Nothing yet'), findsOneWidget);
  });

  testWidgets('shows the newest line first', (tester) async {
    await show(tester, [
      line('first'),
      line('second', after: const Duration(seconds: 1)),
    ]);

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    expect(texts.indexOf('second'), lessThan(texts.indexOf('first')));
  });

  testWidgets('says which extension a line belongs to', (tester) async {
    await show(tester, [line('searching')]);

    expect(find.textContaining('org.example.librivox'), findsOneWidget);
  });

  testWidgets('leaves the id out when the console is one extension’s', (
    tester,
  ) async {
    await show(tester, [line('searching')], only: 'org.example.librivox');

    expect(find.textContaining('org.example.librivox'), findsNothing);
    expect(find.text('searching'), findsOneWidget);
  });

  testWidgets('marks the lines the app wrote as the app’s', (tester) async {
    await show(tester, [
      line('searching'),
      line(
        'Installed 1.4.0',
        fromTheApp: true,
        after: const Duration(seconds: 1),
      ),
    ]);

    expect(find.textContaining('Kikuyomi'), findsOneWidget);
  });

  testWidgets('shows the time a line was written', (tester) async {
    await show(tester, [line('searching')]);

    final clock = _at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    expect(
      find.textContaining(
        '${two(clock.hour)}:${two(clock.minute)}:${two(clock.second)}',
      ),
      findsOneWidget,
    );
  });

  test('as text, for pasting into a bug report', () {
    expect(
      consoleAsText([
        line('searching', level: ExtensionLogLevel.debug),
        line('it broke', level: ExtensionLogLevel.error, fromTheApp: true),
      ]),
      '2026-09-23T09:41:12.000Z DEBUG org.example.librivox: searching\n'
      '2026-09-23T09:41:12.000Z ERROR org.example.librivox (Kikuyomi): '
      'it broke',
    );
  });

  group('what the console keeps', () {
    test('an extension’s own messages, as it wrote them', () {
      final console = ExtensionConsole(clock: FakeClock(_at));

      console.write(
        ExtensionLogMessage(
          extensionId: 'org.example.librivox',
          level: ExtensionLogLevel.warn,
          text: 'the page had no books',
          at: _at,
        ),
      );

      final kept = console.lines.single;
      expect(kept.text, 'the page had no books');
      expect(kept.level, ExtensionLogLevel.warn);
      expect(kept.fromTheApp, isFalse);
    });

    test('what the app has to say about one, as a failure', () {
      final console = ExtensionConsole(clock: FakeClock(_at));

      console.report(
        'org.example.librivox',
        const ManifestExceptionStandIn('id: missing'),
      );

      final kept = console.lines.single;
      expect(kept.text, contains('id: missing'));
      expect(kept.level, ExtensionLogLevel.error);
      expect(kept.fromTheApp, isTrue);
      expect(console.problemsOf('org.example.librivox'), 1);
      expect(console.problemsOf('org.example.other'), 0);
    });

    test('only the newest, once it is full', () {
      final console = ExtensionConsole(limit: 2, clock: FakeClock(_at));

      for (final text in ['first', 'second', 'third']) {
        console.note('org.example.librivox', text);
      }

      expect(
        [for (final kept in console.lines) kept.text],
        ['second', 'third'],
      );
    });

    test('the lines of one extension, and every extension it knows', () {
      final console = ExtensionConsole(clock: FakeClock(_at));

      console.note('org.example.a', 'one');
      console.note('org.example.b', 'two');

      expect(console.linesOf('org.example.a').single.text, 'one');
      expect(console.extensionIds, {'org.example.a', 'org.example.b'});
    });

    test('nothing, once it is cleared', () async {
      final console = ExtensionConsole(clock: FakeClock(_at));
      addTearDown(console.dispose);
      var signals = 0;
      console.changes.listen((_) => signals++);

      console.note('org.example.librivox', 'one');
      await pumpEventQueue();
      console.clear();
      await pumpEventQueue();

      expect(console.lines, isEmpty);
      expect(signals, 2, reason: 'the line, and the clearing');
    });
  });
}

/// Stands in for a failure the app reports, which is written down as it describes itself.
final class ManifestExceptionStandIn implements Exception {
  const ManifestExceptionStandIn(this.message);

  final String message;

  @override
  String toString() => 'the manifest could not be read: $message';
}
