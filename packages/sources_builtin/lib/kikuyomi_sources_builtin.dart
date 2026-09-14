/// Built-in native sources: Local files, Audiobookshelf and OPDS.
///
/// These implement the same contract as extensions, so the app is a complete audiobook player
/// with nothing installed.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/local/embedded_picture.dart' show EmbeddedPicture;
export 'src/local/folder_book.dart';
export 'src/local/mp3_info.dart';
export 'src/local/mp4_chapters.dart';
