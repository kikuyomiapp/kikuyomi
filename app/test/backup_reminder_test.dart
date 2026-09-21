import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/backup_reminder.dart';

void main() {
  late List<String> pressed;

  Widget reminder() => MaterialApp(
    home: Scaffold(
      body: BackupReminderCard(
        onChooseFolder: () => pressed.add('choose folder'),
        onNotNow: () => pressed.add('not now'),
      ),
    ),
  );

  setUp(() => pressed = []);

  testWidgets('says why a backup folder matters', (tester) async {
    await tester.pumpWidget(reminder());
    expect(find.text('Back up your library'), findsOneWidget);
    expect(
      find.text(
        'Choose a folder for automatic backups, so your library and '
        'listening progress survive reinstalling the app.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('chooses a folder', (tester) async {
    await tester.pumpWidget(reminder());
    await tester.tap(find.text('Choose folder'));
    expect(pressed, ['choose folder']);
  });

  testWidgets('can be put off', (tester) async {
    await tester.pumpWidget(reminder());
    await tester.tap(find.text('Not now'));
    expect(pressed, ['not now']);
  });
}
