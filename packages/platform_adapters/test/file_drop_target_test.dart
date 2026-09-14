import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi_platform_adapters/src/drop/file_drop_target.dart';

/// Sends [method] to the app over `desktop_drop`'s channel, as the plugin's native side does while
/// something is dragged across the window.
///
/// This is the plugin's own protocol, so these tests are what notices if an upgrade changes it.
Future<void> platformSends(String method, [Object? arguments]) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'desktop_drop',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );

/// Where the drag is, in window coordinates: inside the target whatever the pixel ratio.
const inside = [10.0, 10.0];

/// A target filling the window, recording what it reports in [heard]. A pixel ratio of one keeps
/// the plugin's scaling of positions on Windows out of the way.
Widget target(List<String> heard, {bool enabled = true}) => MediaQuery(
  data: const MediaQueryData(),
  child: FileDropTarget(
    enabled: enabled,
    onDragEntered: () => heard.add('entered'),
    onDragExited: () => heard.add('exited'),
    onDropped: (paths) => heard.add('dropped ${paths.join(' | ')}'),
    child: const SizedBox.expand(),
  ),
);

void main() {
  // Elsewhere the target is only its child, and the plugin never hears of it.
  final skip = !platformReportsDroppedPaths;

  testWidgets('reports something dragged over it, and the drag leaving', (
    tester,
  ) async {
    final heard = <String>[];
    await tester.pumpWidget(target(heard));

    await platformSends('entered', inside);
    await platformSends('updated', inside);
    await platformSends('exited');
    expect(heard, ['entered', 'exited']);
  }, skip: skip);

  testWidgets('reports the paths dropped on it, after the drag leaving', (
    tester,
  ) async {
    final heard = <String>[];
    await tester.pumpWidget(target(heard));

    await platformSends('entered', inside);
    await platformSends('performOperation', [
      r'C:\Books\One.m4b',
      r'C:\Books\Two',
    ]);
    expect(heard, [
      'entered',
      'exited',
      r'dropped C:\Books\One.m4b | C:\Books\Two',
    ]);
  }, skip: skip);

  testWidgets('reports nothing while it is disabled', (tester) async {
    final heard = <String>[];
    await tester.pumpWidget(target(heard, enabled: false));

    await platformSends('entered', inside);
    await platformSends('performOperation', [r'C:\Books\One.m4b']);
    expect(heard, isEmpty);
  }, skip: skip);

  testWidgets('reports a drag over it as leaving when it is disabled', (
    tester,
  ) async {
    final heard = <String>[];
    await tester.pumpWidget(target(heard));
    await platformSends('entered', inside);

    await tester.pumpWidget(target(heard, enabled: false));
    expect(heard, ['entered', 'exited']);
  }, skip: skip);
}
