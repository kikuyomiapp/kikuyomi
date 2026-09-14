/// Gzip framing for backup files, with the completeness check `dart:io` leaves out.
///
/// `GZipCodec` reports damaged data, but not missing data: a file cut short, by a sync client that
/// had not finished or a disk that filled up, decodes to whatever was there without complaint. For a
/// backup that is the worst failure there is, a restore that quietly brings back half a library. So
/// after decoding, the gzip trailer is checked here: its last eight bytes hold the CRC-32 and the
/// length of the uncompressed data, and a file cut short cannot match both.
///
/// A backup file is always a single gzip member, which is what [gzipFrame] writes.
library;

import 'dart:io';
import 'dart:typed_data';

/// [payload], gzipped.
Uint8List gzipFrame(List<int> payload) {
  final encoded = gzip.encode(payload);
  return encoded is Uint8List ? encoded : Uint8List.fromList(encoded);
}

/// The payload of [bytes], a single-member gzip file.
///
/// Throws [FormatException] when [bytes] are not gzip, are damaged, or are incomplete.
List<int> gunzipFrame(List<int> bytes) {
  // Ten bytes of header and eight of trailer are the least any gzip file holds.
  if (bytes.length < 18) {
    throw const FormatException('too short to be a gzip file');
  }
  if (bytes[0] != 0x1f || bytes[1] != 0x8b) {
    throw const FormatException('not a gzip file');
  }
  final payload = gzip.decode(bytes);
  final crc = _uint32At(bytes, bytes.length - 8);
  final length = _uint32At(bytes, bytes.length - 4);
  // The trailer records the length modulo 2^32.
  if (length != payload.length & 0xffffffff || crc != _crc32(payload)) {
    throw const FormatException('the file is incomplete');
  }
  return payload;
}

/// A little-endian unsigned 32-bit integer.
int _uint32At(List<int> bytes, int offset) =>
    (bytes[offset] & 0xff) |
    (bytes[offset + 1] & 0xff) << 8 |
    (bytes[offset + 2] & 0xff) << 16 |
    (bytes[offset + 3] & 0xff) << 24;

/// The CRC-32 gzip uses (ISO 3309), by the usual table.
final _crcTable = Uint32List.fromList([
  for (var n = 0; n < 256; n++) _crcEntry(n),
]);

int _crcEntry(int n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return crc ^ 0xffffffff;
}
