/// Any audio file of a local book, read by whichever reader its format needs.
///
/// §3.10's Local source takes a single file as a book and a folder of files as one, and reads each
/// file for its duration, tags, chapters and cover. The readers differ by format; what a book is
/// made of does not. This picks the reader by the file's extension, as the file dialog and a folder
/// scan choose files, and gives every format's answer in one shape.
library;

import 'embedded_chapter.dart';
import 'embedded_picture.dart';
import 'flac_info.dart';
import 'mp3_info.dart';
import 'mp4_chapters.dart';
import 'ogg_info.dart';

/// The formats local audio is read in. What decides whether a device can play a file, so an Ogg
/// file counts as Vorbis or Opus by what its stream holds, not by its extension.
enum LocalAudioFormat {
  mp3,

  /// AAC or ALAC in an MPEG-4 file: M4B, M4A or MP4.
  mp4,
  flac,
  oggVorbis,
  oggOpus,
}

/// What an audio file says about itself, whatever its format.
final class LocalAudioInfo {
  const LocalAudioInfo({
    required this.format,
    required this.durationMs,
    required this.durationIsEstimate,
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.composer,
    this.trackNumber,
    this.discNumber,
    this.chapters = const [],
    this.cover,
  });

  /// As the file's contents show it, which for Ogg is more than its extension says.
  final LocalAudioFormat format;
  final int durationMs;

  /// True when [durationMs] was worked out rather than read, which §4.5 treats as provisional: an
  /// MP3 whose frames nothing counts, or a FLAC file whose STREAMINFO does not count its samples.
  final bool durationIsEstimate;

  final String? title;
  final String? artist;
  final String? albumArtist;
  final String? album;

  /// Which audiobook taggers commonly use for the narrator.
  final String? composer;
  final int? trackNumber;
  final int? discNumber;

  /// Embedded chapter markers, in order of their start.
  final List<EmbeddedChapter> chapters;

  /// The embedded cover. Always null unless [readLocalAudioInfo] was asked for it.
  final EmbeddedPicture? cover;

  /// The book's title, when the file is a book of its own.
  ///
  /// An MP4 audiobook names itself in its title tag, as iTunes-style taggers do. The other formats
  /// follow music's tagging, where the title names a track, as a chapter in a book's folder, and the
  /// album names the whole work, so the album comes first.
  String? get bookTitle => switch (format) {
    LocalAudioFormat.mp4 => title ?? album,
    _ => album ?? title,
  };

  /// The book's author, when the file is a book of its own: from the artist or the album artist,
  /// in the same order of trust as [bookTitle].
  String? get author => switch (format) {
    LocalAudioFormat.mp4 => artist ?? albumArtist,
    _ => albumArtist ?? artist,
  };
}

/// The extensions of the audio files local books are read from, in lower case: what the file dialog
/// offers, what a folder scan takes as a book's tracks, and what a dropped file is added as.
const audioExtensions = {
  'mp3',
  'm4a',
  'm4b',
  'mp4',
  'flac',
  'ogg',
  'oga',
  'opus',
};

/// Reads [source], the contents of a file whose extension is [extension], and its cover if
/// [withCover] is true.
///
/// The extension picks the reader: `mp3` the MP3 reader; `flac` the FLAC reader; `ogg`, `oga` and
/// `opus` the Ogg reader, which tells Vorbis from Opus by the stream itself; and anything else the
/// MPEG-4 reader, as M4B, M4A and MP4 files need. It is taken in any case.
///
/// Returns null when the contents are not the format the extension names. Throws a
/// [FormatException] when they are, but are damaged, or are a kind of that format this cannot time,
/// as each reader describes.
Future<LocalAudioInfo?> readLocalAudioInfo(
  ByteSource source, {
  required String extension,
  bool withCover = false,
}) async {
  switch (extension.toLowerCase()) {
    case 'mp3':
      final info = await readMp3Info(source, withCover: withCover);
      if (info == null) return null;
      return LocalAudioInfo(
        format: LocalAudioFormat.mp3,
        durationMs: info.durationMs,
        durationIsEstimate: info.durationIsEstimate,
        title: info.title,
        artist: info.artist,
        albumArtist: info.albumArtist,
        album: info.album,
        composer: info.composer,
        trackNumber: info.trackNumber,
        discNumber: info.discNumber,
        cover: info.cover,
      );
    case 'flac':
      final info = await readFlacInfo(source, withCover: withCover);
      if (info == null) return null;
      return LocalAudioInfo(
        format: LocalAudioFormat.flac,
        durationMs: info.durationMs,
        durationIsEstimate: info.durationIsEstimate,
        title: info.title,
        artist: info.artist,
        albumArtist: info.albumArtist,
        album: info.album,
        composer: info.composer,
        trackNumber: info.trackNumber,
        discNumber: info.discNumber,
        chapters: info.chapters,
        cover: info.cover,
      );
    case 'ogg' || 'oga' || 'opus':
      final info = await readOggInfo(source, withCover: withCover);
      if (info == null) return null;
      return LocalAudioInfo(
        format: switch (info.codec) {
          OggCodec.vorbis => LocalAudioFormat.oggVorbis,
          OggCodec.opus => LocalAudioFormat.oggOpus,
        },
        durationMs: info.durationMs,
        durationIsEstimate: false,
        title: info.title,
        artist: info.artist,
        albumArtist: info.albumArtist,
        album: info.album,
        composer: info.composer,
        trackNumber: info.trackNumber,
        discNumber: info.discNumber,
        chapters: info.chapters,
        cover: info.cover,
      );
    default:
      final info = await readMp4Info(source, withCover: withCover);
      if (info == null) return null;
      return LocalAudioInfo(
        format: LocalAudioFormat.mp4,
        durationMs: info.durationMs,
        durationIsEstimate: false,
        title: info.title,
        artist: info.artist,
        albumArtist: info.albumArtist,
        album: info.album,
        composer: info.composer,
        trackNumber: info.trackNumber,
        discNumber: info.discNumber,
        chapters: [
          for (final chapter in info.chapters?.chapters ?? const <Mp4Chapter>[])
            EmbeddedChapter(startMs: chapter.startMs, title: chapter.title),
        ],
        cover: info.cover,
      );
  }
}
