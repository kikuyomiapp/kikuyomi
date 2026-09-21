// Builders for FLAC and Ogg files, byte by byte, shared by the local source's tests. The audio in
// them is filler: no recording of any kind is in the repository.
//
// The checksums are worked out here bit by bit, apart from the readers' own tables, so that a
// mistake in one does not hide the same mistake in the other.

import 'dart:convert';
import 'dart:typed_data';

List<int> le16(int v) => [v & 0xFF, v >> 8 & 0xFF];

List<int> le32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

List<int> be32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

// Vorbis comments and pictures, which FLAC and Ogg share.

/// A Vorbis comment structure: the vendor string, then each of [comments], such as `TITLE=A Book`,
/// each preceded by its length.
List<int> vorbisComments(List<String> comments, {String vendor = 'tests'}) => [
  ...le32(utf8.encode(vendor).length),
  ...utf8.encode(vendor),
  ...le32(comments.length),
  for (final comment in comments) ...[
    ...le32(utf8.encode(comment).length),
    ...utf8.encode(comment),
  ],
];

/// The FLAC picture structure holding [image]. [type] 3 is the front cover.
List<int> pictureStructure({
  required List<int> image,
  int type = 3,
  String mimeType = 'image/jpeg',
  String description = '',
}) => [
  ...be32(type),
  ...be32(mimeType.length),
  ...ascii.encode(mimeType),
  ...be32(utf8.encode(description).length),
  ...utf8.encode(description),
  ...be32(600), // width
  ...be32(600), // height
  ...be32(24), // colour depth
  ...be32(0), // colours in a palette
  ...be32(image.length),
  ...image,
];

/// A `METADATA_BLOCK_PICTURE` comment holding [image].
String pictureComment({
  required List<int> image,
  int type = 3,
  String mimeType = 'image/jpeg',
}) =>
    'METADATA_BLOCK_PICTURE='
    '${base64.encode(pictureStructure(image: image, type: type, mimeType: mimeType))}';

// FLAC.

/// A metadata block: its type, whether it is the last, and its length, then [body].
List<int> metadataBlock(int type, List<int> body, {bool last = false}) => [
  (last ? 0x80 : 0) | type,
  body.length >> 16 & 0xFF,
  body.length >> 8 & 0xFF,
  body.length & 0xFF,
  ...body,
];

/// The body of a STREAMINFO block: block sizes, frame sizes, then the sample rate, channels, bits
/// per sample and number of samples packed into 64 bits, then an MD5 left as zeros.
List<int> streamInfo({
  int sampleRate = 44100,
  int channels = 2,
  int bitsPerSample = 16,
  int totalSamples = 0,
  int minBlockSize = 4096,
  int maxBlockSize = 4096,
}) {
  final packed =
      sampleRate << 44 |
      (channels - 1) << 41 |
      (bitsPerSample - 1) << 36 |
      totalSamples;
  return [
    minBlockSize >> 8,
    minBlockSize & 0xFF,
    maxBlockSize >> 8,
    maxBlockSize & 0xFF,
    ...List.filled(6, 0), // frame sizes, unknown
    ...(ByteData(8)..setUint64(0, packed)).buffer.asUint8List(),
    ...List.filled(16, 0),
  ];
}

/// A FLAC file: the marker, STREAMINFO from [info], then [blocks] as they are given, each a type and
/// a body, with the last flag on the last of them, then [audio].
List<int> flac({
  List<int>? info,
  List<(int, List<int>)> blocks = const [],
  List<int> audio = const [],
}) => [
  ...ascii.encode('fLaC'),
  ...metadataBlock(0, info ?? streamInfo(), last: blocks.isEmpty),
  for (final (i, (type, body)) in blocks.indexed)
    ...metadataBlock(type, body, last: i == blocks.length - 1),
  ...audio,
];

/// A FLAC frame header with its CRC-8: fixed or [variable] blocking, [number] the frame number or
/// the first sample's number, then the block size and sample rate codes, the channel assignment and
/// sample size code, and [extra] bytes a block size or sample rate code says follow the number.
List<int> frameHeader({
  required int number,
  bool variable = false,
  int blockSizeCode = 12, // 4096
  int sampleRateCode = 9, // 44.1 kHz
  int channelCode = 1, // two channels
  int sampleSizeCode = 4, // 16 bits
  List<int> extra = const [],
}) {
  final header = [
    0xFF,
    variable ? 0xF9 : 0xF8,
    blockSizeCode << 4 | sampleRateCode,
    channelCode << 4 | sampleSizeCode << 1,
    ...codedNumber(number),
    ...extra,
  ];
  return [...header, crc8(header)];
}

/// [value] in the UTF-8-like code FLAC frame headers number frames with.
List<int> codedNumber(int value) {
  if (value < 0x80) return [value];
  var bytes = 2;
  while (value >= 1 << (5 * bytes + 1)) {
    bytes++;
  }
  return [
    (0xFF << (8 - bytes)) & 0xFF | value >> (6 * (bytes - 1)),
    for (var k = bytes - 2; k >= 0; k--) 0x80 | value >> (6 * k) & 0x3F,
  ];
}

/// CRC-8 with polynomial x^8 + x^2 + x + 1, bit by bit.
int crc8(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 0x80 != 0 ? (crc << 1 ^ 0x07) & 0xFF : crc << 1 & 0xFF;
    }
  }
  return crc;
}

// Ogg.

/// A Vorbis identification header.
List<int> vorbisId({int channels = 2, int sampleRate = 44100}) => [
  1,
  ...ascii.encode('vorbis'),
  ...le32(0), // version
  channels,
  ...le32(sampleRate),
  ...le32(0), // maximum bitrate
  ...le32(96000), // nominal bitrate
  ...le32(0), // minimum bitrate
  0xB8, // block sizes
  1, // framing
];

/// A Vorbis comment header holding [comments].
List<int> vorbisCommentHeader(List<String> comments) => [
  3,
  ...ascii.encode('vorbis'),
  ...vorbisComments(comments),
  1, // framing
];

/// A stand-in for a Vorbis setup header, which the reader never looks inside.
List<int> vorbisSetup() => [
  5,
  ...ascii.encode('vorbis'),
  ...List.filled(40, 7),
];

/// An Opus identification header.
List<int> opusHead({
  int channels = 1,
  int preSkip = 312,
  int inputSampleRate = 44100,
}) => [
  ...ascii.encode('OpusHead'),
  1, // version
  channels,
  ...le16(preSkip),
  ...le32(inputSampleRate),
  0, 0, // output gain
  0, // channel mapping family
];

/// An Opus comment header holding [comments].
List<int> opusTags(List<String> comments) => [
  ...ascii.encode('OpusTags'),
  ...vorbisComments(comments),
];

/// One Ogg page carrying [body] in segments of the lengths [lacing] gives, its checksum filled in.
List<int> oggPage({
  required List<int> lacing,
  required List<int> body,
  int serial = 0x4B494B55,
  int sequence = 0,
  int granule = 0,
  bool beginsStream = false,
  bool continued = false,
  bool endsStream = false,
}) {
  final page = [
    ...ascii.encode('OggS'),
    0, // version
    (continued ? 1 : 0) | (beginsStream ? 2 : 0) | (endsStream ? 4 : 0),
    ...(ByteData(8)..setInt64(0, granule, Endian.little)).buffer.asUint8List(),
    ...le32(serial),
    ...le32(sequence),
    0, 0, 0, 0, // checksum, filled in below
    lacing.length,
    ...lacing,
    ...body,
  ];
  page.setRange(22, 26, le32(oggCrc(page)));
  return page;
}

/// Ogg's CRC-32 of a page whose checksum field is still zeros: polynomial 0x04C11DB7, unreflected,
/// bit by bit.
int oggCrc(List<int> page) {
  var crc = 0;
  for (final byte in page) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 0x80000000 != 0
          ? (crc << 1 ^ 0x04C11DB7) & 0xFFFFFFFF
          : crc << 1 & 0xFFFFFFFF;
    }
  }
  return crc;
}

/// The pages that carry [packet] from the start of a page, [maxSegments] lacing values to a page,
/// as an encoder lays a packet out. The page on which it ends has [granule]; any before it end no
/// packet and have -1. Numbered from [sequence].
List<List<int>> packetPages(
  List<int> packet, {
  int serial = 0x4B494B55,
  int sequence = 0,
  int granule = 0,
  int maxSegments = 255,
  bool beginsStream = false,
}) {
  final lacing = [
    ...List.filled(packet.length ~/ 255, 255),
    packet.length % 255,
  ];
  final pages = <List<int>>[];
  var at = 0;
  for (var start = 0; start < lacing.length; start += maxSegments) {
    final end = start + maxSegments < lacing.length
        ? start + maxSegments
        : lacing.length;
    final pageLacing = lacing.sublist(start, end);
    final length = pageLacing.fold(0, (sum, lace) => sum + lace);
    pages.add(
      oggPage(
        lacing: pageLacing,
        body: packet.sublist(at, at + length),
        serial: serial,
        sequence: sequence + pages.length,
        granule: end == lacing.length ? granule : -1,
        beginsStream: beginsStream && start == 0,
        continued: start > 0,
      ),
    );
    at += length;
  }
  return pages;
}

/// An Ogg file of one stream: [identification] alone on the first page, [comments] from the second
/// page on, [maxSegments] lacing values to a page, then [setup] when given, and [audioPages] pages of
/// filler audio whose granule positions climb to [endGranule] on the last page.
List<int> oggFile({
  required List<int> identification,
  required List<int> comments,
  List<int>? setup,
  required int endGranule,
  int serial = 0x4B494B55,
  int maxSegments = 255,
  int audioPages = 3,
  bool endsStream = true,
}) {
  final pages = [
    ...packetPages(identification, serial: serial, beginsStream: true),
  ];
  pages.addAll(
    packetPages(
      comments,
      serial: serial,
      sequence: pages.length,
      maxSegments: maxSegments,
    ),
  );
  if (setup != null) {
    pages.addAll(packetPages(setup, serial: serial, sequence: pages.length));
  }
  for (var i = 1; i <= audioPages; i++) {
    pages.add(
      oggPage(
        lacing: const [200],
        body: List.filled(200, 0x55 + i),
        serial: serial,
        sequence: pages.length,
        granule: endGranule * i ~/ audioPages,
        endsStream: endsStream && i == audioPages,
      ),
    );
  }
  return [for (final page in pages) ...page];
}
