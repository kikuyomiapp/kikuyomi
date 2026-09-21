/// The FLAC picture structure, which carries cover art in FLAC files and, encoded in base64, in Ogg
/// Vorbis and Ogg Opus files.
///
/// A FLAC file keeps each picture in a PICTURE metadata block. The Ogg codecs have no metadata
/// blocks, so the same structure goes into a `METADATA_BLOCK_PICTURE` Vorbis comment instead. Either
/// way its fields are, big-endian:
///
/// `type(4) mimeLength(4) mime descriptionLength(4) description width(4) height(4) depth(4)
/// colours(4) dataLength(4) data`
library;

import 'dart:typed_data';

import 'embedded_picture.dart';

/// The picture type 3, which marks the front cover. 0 is anything not listed, 4 the back cover, and
/// other values such things as the artist or a file icon.
const frontCoverType = 3;

/// The picture type at the start of [structure], or null when it is too short to hold one.
int? flacPictureType(Uint8List structure) =>
    structure.length < 4 ? null : ByteData.sublistView(structure).getUint32(0);

/// The image in [structure], or null when it holds none this can use.
///
/// That is when a MIME type of `-->` says the structure holds the address of an image rather than
/// the image; when a length runs past the end of the structure; when the image is larger than
/// [maxPictureBytes]; or when the image's type can be told from neither its bytes nor its MIME type.
/// A damaged picture costs the file its cover, not its audio, so none of these is an error.
///
/// The image's bytes are a view of [structure], not a copy.
EmbeddedPicture? parseFlacPicture(Uint8List structure) {
  final view = ByteData.sublistView(structure);
  var p = 4;

  // The length field at p, or null when it, or the bytes it counts, run past the end.
  int? length() {
    if (structure.length - p < 4) return null;
    final value = view.getUint32(p);
    p += 4;
    return value > structure.length - p ? null : value;
  }

  final mimeLength = length();
  if (mimeLength == null) return null;
  final mime = String.fromCharCodes(structure, p, p + mimeLength);
  p += mimeLength;
  if (mime == '-->') return null;

  final descriptionLength = length();
  if (descriptionLength == null) return null;
  // Past the description, then width, height, colour depth and number of colours.
  p += descriptionLength + 16;
  if (p > structure.length) return null;

  final dataLength = length();
  if (dataLength == null || dataLength == 0 || dataLength > maxPictureBytes) {
    return null;
  }
  final bytes = Uint8List.sublistView(structure, p, p + dataLength);
  final mimeType = pictureMimeType(bytes, declared: mime);
  return mimeType == null
      ? null
      : EmbeddedPicture(mimeType: mimeType, bytes: bytes);
}
