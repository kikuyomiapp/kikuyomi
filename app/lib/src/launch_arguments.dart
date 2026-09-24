/// What the app was started with.
///
/// Two things arrive on the command line, both for driving the app without a dialog:
///
/// - a book file or folder, which is imported and opened at start (§5.1);
/// - `--extension <folder>`, which installs an extension from a folder, so that an author can rebuild
///   and restart in one command rather than tapping through the picker each time (§3.11's edit and
///   reload loop, on a desktop).
///
/// Flags this app does not know are ignored rather than refused: a Flutter build may be handed flags
/// of its own, and a typo should not stop the app from starting.
library;

/// The arguments `main` was given, read.
final class LaunchArguments {
  const LaunchArguments({this.openOnLaunch, this.extensionFolders = const []});

  /// Reads the arguments as passed, in order.
  ///
  /// `--extension` takes the path after it, and `--extension=<path>` carries it. Several are allowed,
  /// and they are installed in the order they were given. The first argument that is not a flag and
  /// not a flag's value is the book to open; later ones are ignored, since the app opens one book.
  factory LaunchArguments.parse(List<String> arguments) {
    String? book;
    final extensions = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument == _extensionFlag) {
        // A flag with nothing after it: the author meant to name a folder, so say nothing and install
        // nothing rather than treat the next flag as a path.
        if (i + 1 < arguments.length) extensions.add(arguments[++i]);
        continue;
      }
      if (argument.startsWith('$_extensionFlag=')) {
        final path = argument.substring(_extensionFlag.length + 1);
        if (path.isNotEmpty) extensions.add(path);
        continue;
      }
      if (argument.startsWith('-')) continue;
      book ??= argument;
    }
    return LaunchArguments(
      openOnLaunch: book,
      extensionFolders: List.unmodifiable(extensions),
    );
  }

  static const _extensionFlag = '--extension';

  /// A book file or folder to import and open at start, or null.
  final String? openOnLaunch;

  /// Folders to install an extension from at start, in the order they were given.
  final List<String> extensionFolders;
}
