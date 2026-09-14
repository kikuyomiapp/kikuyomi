import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi_design_system/kikuyomi_design_system.dart';

Widget cover(File? file, {double size = 64}) => MaterialApp(
  home: Center(
    child: BookCover(file: file, size: size, semanticLabel: 'Cover of A Book'),
  ),
);

final placeholder = find.byIcon(Icons.headphones);

/// Shows the cover of [file] and waits for its image to load or fail to, then rebuilds with the
/// outcome.
///
/// Reading a file takes real time, which a widget test's fake time never lets pass. So the widget is
/// first built inside [WidgetTester.runAsync], where the read it starts can finish; a read started
/// in fake time would leave the wait for it hanging.
Future<void> showLoaded(WidgetTester tester, File file) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(cover(file));
    final image = find.byType(Image);
    await precacheImage(
      tester.widget<Image>(image).image,
      tester.element(image),
      onError: (_, _) {},
    );
  });
  await tester.pump();
}

/// A small PNG drawn here in one colour, so that no image of anything is in the repository.
Future<List<int>> drawnPng(WidgetTester tester) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 8, 8),
      Paint()..color = const Color(0xFF3949AB),
    );
    final image = await recorder.endRecording().toImage(8, 8);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

void main() {
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('kikuyomi_book_cover_');
  });

  tearDown(() => folder.deleteSync(recursive: true));

  File put(String name, List<int> bytes) =>
      File('${folder.path}/$name')..writeAsBytesSync(bytes);

  testWidgets('shows headphones for a book with no cover', (tester) async {
    await tester.pumpWidget(cover(null));
    expect(placeholder, findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('shows headphones for a file that cannot be decoded', (
    tester,
  ) async {
    await showLoaded(tester, put('cover.jpg', 'Not an image.'.codeUnits));
    expect(placeholder, findsOneWidget);
  });

  testWidgets('shows headphones for a file that has gone', (tester) async {
    await showLoaded(tester, File('${folder.path}/gone.jpg'));
    expect(placeholder, findsOneWidget);
  });

  testWidgets('shows a cover that decodes', (tester) async {
    await showLoaded(tester, put('cover.png', await drawnPng(tester)));
    expect(placeholder, findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  });

  testWidgets('decodes the image no larger than it is shown', (tester) async {
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await showLoaded(tester, put('cover.png', await drawnPng(tester)));

    final image = tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(image.width, 192);
    expect(image.height, 192);
    expect(image.policy, ResizeImagePolicy.fit);
    expect(tester.getSize(find.byType(BookCover)), const Size(64, 64));
  });

  testWidgets('is announced by its label', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(cover(null));
    expect(find.bySemanticsLabel('Cover of A Book'), findsOneWidget);
    semantics.dispose();
  });
}
