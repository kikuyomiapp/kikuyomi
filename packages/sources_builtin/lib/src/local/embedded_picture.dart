/// Pictures embedded in audio files, such as a book's cover art.
///
/// §4.3 gives a book a cover, and a local book's files often carry one of their own: an ID3v2
/// `APIC` frame in an MP3, a `covr` item in an MP4. The readers return one only when asked, because
/// a picture costs memory that probing a folder's files for their tags and durations never needs.
library;

import 'dart:typed_data';

/// An image read out of an audio file.
final class EmbeddedPicture {
  const EmbeddedPicture({required this.mimeType, required this.bytes});

  /// Such as `image/jpeg` or `image/png`. Taken from the image's own first bytes when they say,
  /// since taggers name the type wrongly more often than an image misstates its own signature.
  final String mimeType;

  /// The encoded image, as the file stores it. It is not copied, so treat it as read-only.
  final Uint8List bytes;

  @override
  String toString() => 'EmbeddedPicture($mimeType, ${bytes.length} bytes)';
}

/// Pictures larger than this are skipped. Cover art runs to a few hundred kilobytes and seldom to a
/// few megabytes; the bound stops a damaged file that claims a far larger one from allocating it.
const maxPictureBytes = 16 * 1024 * 1024;

/// The MIME type of an embedded image, or null when it cannot be told.
///
/// [bytes] decide when they begin with a JPEG, PNG, GIF or WebP signature. Otherwise the type comes
/// from [declared], what the file states: lower-cased, with `image/jpg` corrected, and with a bare
/// format such as ID3v2.2's `PNG` given its `image/` prefix.
String? pictureMimeType(Uint8List bytes, {String? declared}) {
  bool startsWith(List<int> signature, {int at = 0}) {
    if (bytes.length < at + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[at + i] != signature[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  // GIF8, as in GIF87a and GIF89a.
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  // RIFF, a four-byte size, then WEBP.
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], at: 8)) {
    return 'image/webp';
  }

  final type = declared?.trim().toLowerCase() ?? '';
  return switch (type) {
    '' || 'image/' => null,
    'image/jpg' || 'jpg' || 'jpeg' => 'image/jpeg',
    _ when !type.contains('/') => 'image/$type',
    _ => type,
  };
}
