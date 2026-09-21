import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/app_version.dart';

void main() {
  test('the version written into backups is the one pubspec.yaml gives', () {
    // flutter test runs in the app's own folder.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);
    expect(appVersion, version);
  });
}
