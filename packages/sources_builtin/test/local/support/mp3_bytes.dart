// Builders for MP3 files, byte by byte, shared by the local source's tests. No audio file of any
// kind is in the repository.

import 'dart:convert';
import 'dart:typed_data';

List<int> u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

List<int> syncsafe(int v) => [
  v >> 21 & 0x7F,
  v >> 14 & 0x7F,
  v >> 7 & 0x7F,
  v & 0x7F,
];

/// An ID3v2.3 text frame. The value is Latin-1 unless [encoding] says otherwise.
List<int> frame3(String id, List<int> value, {int encoding = 0}) => [
  ...ascii.encode(id),
  ...u32(value.length + 1),
  0,
  0,
  encoding,
  ...value,
];

/// An ID3v2.4 text frame in UTF-8, with its syncsafe size.
List<int> frame4(String id, String value) {
  final bytes = utf8.encode(value);
  return [
    ...ascii.encode(id),
    ...syncsafe(bytes.length + 1),
    0,
    0,
    3,
    ...bytes,
  ];
}

/// An ID3v2.2 text frame: a three-letter id and a three-byte size.
List<int> frame2(String id, String value) {
  final bytes = latin1.encode(value);
  final size = bytes.length + 1;
  return [
    ...ascii.encode(id),
    size >> 16 & 0xFF,
    size >> 8 & 0xFF,
    size & 0xFF,
    0,
    ...bytes,
  ];
}

List<int> id3(int version, List<int> frames, {int padding = 32}) => [
  ...ascii.encode('ID3'),
  version,
  0,
  0,
  ...syncsafe(frames.length + padding),
  ...frames,
  ...List.filled(padding, 0),
];

/// One MPEG-1 Layer III frame at 128 kbps, 44.1 kHz and stereo, which is 417 bytes. [body] follows
/// the four-byte header.
List<int> audioFrame([List<int> body = const []]) => [
  0xFF,
  0xFB,
  0x90,
  0x00,
  ...body,
  ...List.filled(417 - 4 - body.length, 0),
];

List<int> audio(int frames) => [
  for (var i = 0; i < frames; i++) ...audioFrame(),
];

/// A first frame whose Xing or Info header counts [frames]. It sits after the 32 bytes of side
/// information a stereo MPEG-1 frame carries.
List<int> xingFrame(int frames, {String id = 'Xing'}) => audioFrame([
  ...List.filled(32, 0),
  ...ascii.encode(id),
  ...u32(1),
  ...u32(frames),
]);

/// A first frame whose VBRI header counts [frames]: id, version, delay, quality, bytes, frames.
List<int> vbriFrame(int frames) => audioFrame([
  ...List.filled(32, 0),
  ...ascii.encode('VBRI'),
  0,
  1,
  0,
  0,
  0,
  75,
  ...u32(0),
  ...u32(frames),
]);

/// An ID3v1.1 tag: 128 bytes, with the track number in the comment's last byte.
List<int> id3v1({
  required String title,
  required String artist,
  required String album,
  required int track,
}) {
  List<int> field(String value, int length) => [
    ...latin1.encode(value),
    ...List.filled(length - value.length, 0),
  ];
  return [
    ...ascii.encode('TAG'),
    ...field(title, 30),
    ...field(artist, 30),
    ...field(album, 30),
    ...field('2026', 4),
    ...field('', 28),
    0,
    track,
    0,
  ];
}

/// The exact duration of [frames] frames at 44.1 kHz.
int counted(int frames) => frames * 1152 * 1000 ~/ 44100;

/// The duration a bitrate estimate gives [frames] frames of 417 bytes at 128 kbps.
int estimated(int frames) => frames * 417 * 8 * 1000 ~/ 128000;
