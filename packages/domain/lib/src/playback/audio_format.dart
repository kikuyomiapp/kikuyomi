/// Audio formats, and which of them a device can play: §7.3's per-platform capability matrix.
///
/// Each platform's player plays a different set of formats. ExoPlayer on Android and the mpv backend
/// on Windows play nearly everything, Ogg included; AVFoundation on iOS is narrower (Appendix A). A
/// book the device cannot play is refused where it would enter the library, with the format named,
/// rather than added to fail when it is opened.
library;

/// How a file's audio is encoded and packed, as far as that decides whether a player can play it.
enum AudioFormat {
  /// MPEG-1 or MPEG-2 audio, Layer III.
  mp3('MP3'),

  /// AAC or ALAC in an MPEG-4 file: M4B, M4A or MP4.
  mp4('MPEG-4'),
  flac('FLAC'),

  /// Vorbis in an Ogg file.
  oggVorbis('Ogg Vorbis'),

  /// Opus in an Ogg file.
  oggOpus('Ogg Opus');

  const AudioFormat(this.label);

  /// What to call the format when telling the listener about it.
  final String label;
}

/// The audio formats a device's player can play: one row of the capability matrix.
final class PlayableFormats {
  const PlayableFormats(this.formats);

  /// Every format there is.
  static const all = PlayableFormats({...AudioFormat.values});

  final Set<AudioFormat> formats;

  bool canPlay(AudioFormat format) => formats.contains(format);
}

/// A book was not added because this device cannot play the format its audio is in.
final class UnplayableFormatException implements Exception {
  /// [formats] may repeat, as a folder's files do; each is named once.
  UnplayableFormatException(Iterable<AudioFormat> formats)
    : formats = Set.unmodifiable({
        for (final format in AudioFormat.values)
          if (formats.contains(format)) format,
      }) {
    if (this.formats.isEmpty) {
      throw ArgumentError.value(formats, 'formats', 'names no format');
    }
  }

  /// The formats found that this device cannot play: at least one, in the order they are declared.
  final Set<AudioFormat> formats;

  /// What went wrong, as a phrase for a person to read, such as "this device cannot play Ogg Vorbis
  /// audio".
  String get message {
    final labels = [for (final format in formats) format.label];
    final named = labels.length == 1
        ? labels.single
        : '${labels.sublist(0, labels.length - 1).join(', ')} or ${labels.last}';
    return 'this device cannot play $named audio';
  }

  @override
  String toString() => 'UnplayableFormatException: $message';
}
