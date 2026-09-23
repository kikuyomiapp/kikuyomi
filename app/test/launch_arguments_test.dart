// What the app does with its command line: a book to open, and folders to install an extension from.

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/launch_arguments.dart';

void main() {
  LaunchArguments read(List<String> arguments) =>
      LaunchArguments.parse(arguments);

  test('nothing passed asks for nothing', () {
    final arguments = read([]);

    expect(arguments.openOnLaunch, isNull);
    expect(arguments.extensionFolders, isEmpty);
  });

  test('a path on its own is a book to open', () {
    expect(read([r'G:\Books\A Book.m4b']).openOnLaunch, r'G:\Books\A Book.m4b');
  });

  test('--extension takes the folder after it', () {
    final arguments = read(['--extension', r'G:\work\librivox']);

    expect(arguments.extensionFolders, [r'G:\work\librivox']);
    expect(arguments.openOnLaunch, isNull);
  });

  test('--extension=folder carries it', () {
    expect(read([r'--extension=G:\work\librivox']).extensionFolders, [
      r'G:\work\librivox',
    ]);
  });

  test('several extensions are installed in the order they were given', () {
    expect(
      read([
        '--extension',
        'first',
        '--extension=second',
        '--extension',
        'third',
      ]).extensionFolders,
      ['first', 'second', 'third'],
    );
  });

  test('a book and an extension can be asked for at once', () {
    final arguments = read([
      '--extension',
      r'G:\work\librivox',
      r'G:\Books\A Book.m4b',
    ]);

    expect(arguments.extensionFolders, [r'G:\work\librivox']);
    expect(arguments.openOnLaunch, r'G:\Books\A Book.m4b');
  });

  test("a folder named after --extension is not mistaken for the book", () {
    expect(read(['--extension', 'librivox']).openOnLaunch, isNull);
  });

  test('--extension with nothing after it installs nothing', () {
    expect(read(['--extension']).extensionFolders, isEmpty);
    expect(read(['--extension=']).extensionFolders, isEmpty);
  });

  test('a flag this app does not know is ignored', () {
    // A Flutter build is handed flags of its own, and a typo should not stop the app from starting.
    final arguments = read(['--verbose', 'book.m4b', '--trace-startup']);

    expect(arguments.openOnLaunch, 'book.m4b');
    expect(arguments.extensionFolders, isEmpty);
  });

  test('the app opens one book, so later paths are ignored', () {
    expect(read(['first.m4b', 'second.m4b']).openOnLaunch, 'first.m4b');
  });
}
