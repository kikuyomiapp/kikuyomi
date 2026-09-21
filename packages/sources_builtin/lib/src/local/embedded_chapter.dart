/// Chapter markers embedded in audio files.
///
/// §4.5 presents the markers of a book in one file as virtual chapters. An MP4 keeps them in a
/// `chpl` atom or a chapter track (see `mp4_chapters.dart`); FLAC and Ogg files keep them in
/// `CHAPTERnnn` Vorbis comments. Every reader gives them in this one shape.
library;

/// One embedded chapter marker.
final class EmbeddedChapter {
  const EmbeddedChapter({required this.startMs, required this.title});

  /// Offset into the file.
  final int startMs;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is EmbeddedChapter &&
      other.startMs == startMs &&
      other.title == title;

  @override
  int get hashCode => Object.hash(startMs, title);

  @override
  String toString() => 'EmbeddedChapter(${startMs}ms, "$title")';
}
