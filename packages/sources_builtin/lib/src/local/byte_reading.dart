/// Small helpers the FLAC and Ogg readers share for reading a [ByteSource].
library;

import 'dart:typed_data';

import 'mp4_chapters.dart' show ByteSource;

/// Reads exactly [count] bytes at [offset] of [source], or throws a [FormatException] saying what
/// was being read, as [what], when the source ends first. A reader calls this for bytes a file's
/// structure says are there, so running out means the file is truncated.
Future<Uint8List> readExactly(
  ByteSource source,
  int offset,
  int count, {
  required String what,
}) async {
  if (offset < 0 || count < 0 || count > source.length - offset) {
    throw FormatException(
      'the file ends before $what: $count bytes at $offset, of ${source.length}',
    );
  }
  final bytes = await source.read(offset, count);
  if (bytes.length != count) {
    throw FormatException(
      'the file ends before $what: $count bytes at $offset, of ${source.length}',
    );
  }
  return bytes;
}

/// A 28-bit integer stored seven bits to a byte, as ID3v2 sizes are. Null if a byte has its top bit
/// set, which a real tag never does.
int? syncsafeInt(Uint8List bytes, int at) {
  if (bytes.length - at < 4) return null;
  var value = 0;
  for (var i = 0; i < 4; i++) {
    final byte = bytes[at + i];
    if (byte & 0x80 != 0) return null;
    value = value << 7 | byte;
  }
  return value;
}

/// Where the audio after an ID3v2 tag at the start of a file begins, from the tag's first ten bytes
/// in [header], or null when [header] does not open one.
///
/// FLAC and Ogg have no place for an ID3v2 tag, but some taggers put one in front of a FLAC file
/// anyway, and decoders skip it.
int? id3v2End(Uint8List header) {
  if (header.length < 10 ||
      header[0] != 0x49 || // I
      header[1] != 0x44 || // D
      header[2] != 0x33) {
    // 3
    return null;
  }
  final size = syncsafeInt(header, 6);
  if (size == null) return null;
  // A footer, flagged in version 4, repeats the header's ten bytes at the end.
  final footer = header[3] == 4 && header[5] & 0x10 != 0 ? 10 : 0;
  return 10 + size + footer;
}

/// "3" or "3/12" as 3. Null for anything that is not a positive number.
int? leadingNumber(String? value) {
  if (value == null) return null;
  final number = int.tryParse(value.split('/').first.trim());
  return number == null || number <= 0 ? null : number;
}
