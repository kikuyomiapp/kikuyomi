/// Tags, duration and cover art of MP3 files, read in pure Dart.
///
/// §3.10's Local source takes a folder as a book and its files as tracks, and most such folders hold
/// MP3s. The audio plugins learn a file's duration only once they load it, too late to build a
/// book's Timeline from, so it is read from the file itself: counted exactly from the Xing, Info or
/// VBRI header an encoder writes into the first frame, and otherwise estimated from the bitrate.
///
/// Like the MP4 reader it reads only what it needs through a [ByteSource]: the tag's text frames,
/// the first audio frames and the last 128 bytes, however large the file, and one picture when a
/// cover is asked for.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'embedded_picture.dart';
import 'mp4_chapters.dart' show ByteSource;

/// What an MP3 file says about itself.
final class Mp3Info {
  const Mp3Info({
    required this.durationMs,
    required this.durationIsEstimate,
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.composer,
    this.trackNumber,
    this.discNumber,
    this.cover,
  });

  final int durationMs;

  /// True when [durationMs] was worked out from the first frame's bitrate rather than from a frame
  /// count. That is close for a constant-bitrate file and can be well off for a variable-bitrate
  /// one, so §4.5 treats it as provisional.
  final bool durationIsEstimate;

  /// `TIT2`: in a book's folder, usually the chapter's title.
  final String? title;

  /// `TPE1`, conventionally the author.
  final String? artist;

  /// `TPE2`, the album artist, which some taggers use for the author instead.
  final String? albumArtist;

  /// `TALB`: in a book's folder, usually the book's title.
  final String? album;

  /// `TCOM`, which audiobook taggers commonly use for the narrator.
  final String? composer;

  /// `TRCK`, without any "of" count.
  final int? trackNumber;

  /// `TPOS`, without any "of" count.
  final int? discNumber;

  /// `APIC`, or `PIC` in 2.2: the picture the tag marks as the front cover, or failing that its
  /// first picture. Always null unless [readMp3Info] was asked for it.
  final EmbeddedPicture? cover;
}

/// Reads an MP3 file's duration and common tags, and its cover if [withCover] is true.
///
/// Returns null when no run of MPEG audio frames can be found where the audio should start, which
/// is how a file that is not an MP3 shows. Tags come from an ID3v2 tag, versions 2.2 to 2.4, or
/// failing that from an ID3v1 tag at the end.
///
/// The cover is off by default. A picture can run to megabytes and is wanted once for a book, while
/// a folder scan probes every file in the folder for its tags and duration. A picture larger than
/// 16 MB, or whose image type can be told from neither its bytes nor its frame, is skipped.
///
/// Not handled: ID3v2 tags written with unsynchronisation, whose tags are skipped though the audio
/// is still read; compressed or encrypted frames, whose text or picture is skipped likewise; MPEG
/// layers I and II; and free-format bitrates.
Future<Mp3Info?> readMp3Info(ByteSource source, {bool withCover = false}) =>
    _Mp3Reader(source, withCover: withCover).read();

/// Layer III bitrates in kbps, by the header's bitrate index. Index 0 is free format and 15 is
/// invalid; neither is read.
const _mpeg1Bitrates = [
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0, //
];
const _mpeg2Bitrates = [
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0, //
];

/// Sample rates by the header's version bits (MPEG 2.5, reserved, MPEG 2, MPEG 1) and rate index.
const _sampleRates = [
  [11025, 12000, 8000],
  <int>[],
  [22050, 24000, 16000],
  [44100, 48000, 32000],
];

/// The text frames read, by their ids in ID3v2.3 and 2.4 and in 2.2's three-letter form.
const _frameKeys = {
  'TIT2': 'title',
  'TT2': 'title',
  'TPE1': 'artist',
  'TP1': 'artist',
  'TPE2': 'albumArtist',
  'TP2': 'albumArtist',
  'TALB': 'album',
  'TAL': 'album',
  'TCOM': 'composer',
  'TCM': 'composer',
  'TRCK': 'track',
  'TRK': 'track',
  'TPOS': 'disc',
  'TPA': 'disc',
};

/// One MPEG audio frame header.
final class _Frame {
  const _Frame({
    required this.offset,
    required this.mpeg1,
    required this.bitrate,
    required this.sampleRate,
    required this.length,
    required this.crc,
    required this.mono,
  });

  /// Parses the four bytes at [at] in [bytes], a frame starting at [offset] in the file. Returns
  /// null for anything but a Layer III header this reader can use.
  static _Frame? parse(Uint8List bytes, int at, int offset) {
    if (bytes.length - at < 4 || bytes[at] != 0xFF) return null;
    final b1 = bytes[at + 1];
    final b2 = bytes[at + 2];
    final b3 = bytes[at + 3];
    if (b1 & 0xE0 != 0xE0) return null;
    final version = (b1 >> 3) & 3;
    final layer = (b1 >> 1) & 3;
    final bitrateIndex = b2 >> 4;
    final rateIndex = (b2 >> 2) & 3;
    if (version == 1 ||
        layer != 1 ||
        bitrateIndex == 0 ||
        bitrateIndex == 15 ||
        rateIndex == 3) {
      return null;
    }
    final mpeg1 = version == 3;
    final bitrate =
        (mpeg1 ? _mpeg1Bitrates : _mpeg2Bitrates)[bitrateIndex] * 1000;
    final sampleRate = _sampleRates[version][rateIndex];
    final samples = mpeg1 ? 1152 : 576;
    return _Frame(
      offset: offset,
      mpeg1: mpeg1,
      bitrate: bitrate,
      sampleRate: sampleRate,
      length: samples ~/ 8 * bitrate ~/ sampleRate + ((b2 >> 1) & 1),
      crc: b1 & 1 == 0,
      mono: b3 >> 6 == 3,
    );
  }

  final int offset;
  final bool mpeg1;
  final int bitrate;
  final int sampleRate;

  /// The whole frame, header included.
  final int length;

  /// Whether a two-byte checksum follows the header.
  final bool crc;
  final bool mono;

  int get samplesPerFrame => mpeg1 ? 1152 : 576;

  /// The side information after the header, before any Xing or Info header.
  int get sideInfoBytes => mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
}

/// Where the image in an ID3v2 attached picture frame lies in the file.
final class _PictureFrame {
  const _PictureFrame({
    required this.type,
    required this.format,
    required this.offset,
    required this.length,
  });

  /// Parses [head], the start of a picture frame's body, which is at [offset] in the file and is
  /// [length] bytes long in all. Returns null when the frame holds no image, or when its fields
  /// before the image do not end within [head].
  ///
  /// `APIC` is encoding(1), a MIME type ending in a zero byte, picture type(1), a description in
  /// the encoding ending in a null character, then the image. ID3v2.2's `PIC` has a three-letter
  /// image format such as `JPG` where the MIME type would be.
  static _PictureFrame? parse(
    Uint8List head, {
    required int version,
    required int offset,
    required int length,
  }) {
    if (head.isEmpty) return null;
    final encoding = head[0];
    final String format;
    final int typeAt;
    if (version == 2) {
      if (head.length < 4) return null;
      format = String.fromCharCodes(head, 1, 4);
      typeAt = 4;
    } else {
      final nul = head.indexOf(0, 1);
      if (nul < 0) return null;
      format = String.fromCharCodes(head, 1, nul);
      typeAt = nul + 1;
    }
    // A MIME type of "-->" means the frame holds the address of an image rather than the image.
    if (format == '-->' || typeAt >= head.length) return null;
    final imageAt = _pastNull(head, typeAt + 1, encoding);
    if (imageAt == null || imageAt >= length) return null;
    return _PictureFrame(
      type: head[typeAt],
      format: format,
      offset: offset + imageAt,
      length: length - imageAt,
    );
  }

  /// What the picture shows: 3 is the front cover, 4 the back cover, 0 anything not listed, and
  /// other values such things as the artist or a file icon.
  final int type;

  /// The MIME type, or in ID3v2.2 the image format, as the frame states it.
  final String format;

  /// Where the image starts in the file.
  final int offset;

  /// The image's size in bytes.
  final int length;

  bool get isFrontCover => type == 3;
}

final class _Mp3Reader {
  _Mp3Reader(this._source, {required bool withCover}) : _withCover = withCover;

  final ByteSource _source;
  final bool _withCover;

  /// How far past the tag to look for the first frame. Encoders put the audio straight after the
  /// tag; the margin covers padding and stray bytes some taggers leave.
  static const _searchBytes = 64 * 1024;

  /// Text frames larger than this are skipped: titles and names are tiny, and the bound stops a
  /// damaged file claiming a huge one.
  static const _maxTextBytes = 64 * 1024;

  /// How much of a picture frame is read to find where its image begins. The MIME type and the
  /// description before the image run to a few dozen bytes; a frame whose fields run on past this
  /// is taken as damaged and skipped.
  static const _pictureHeadBytes = 4096;

  Future<Mp3Info?> read() async {
    final tags = <String, String>{};
    final (:audioStart, :picture) = await _readId3v2(tags);
    final v1 = await _readId3v1();
    final audioEnd = _source.length - (v1 == null ? 0 : 128);

    final frame = await _firstFrame(audioStart, audioEnd);
    if (frame == null) return null;

    // Read only once the file has shown itself to be an MP3, so a file that is not one costs no
    // picture.
    final cover = picture == null ? null : await _readPicture(picture);
    final frames = await _frameCount(frame);
    final counted = frames != null && frames > 0 ? frames : null;
    String? tag(String key) => tags[key] ?? v1?[key];
    return Mp3Info(
      durationMs: counted != null
          ? counted * frame.samplesPerFrame * 1000 ~/ frame.sampleRate
          : (audioEnd - frame.offset) * 8 * 1000 ~/ frame.bitrate,
      durationIsEstimate: counted == null,
      title: tag('title'),
      artist: tag('artist'),
      albumArtist: tag('albumArtist'),
      album: tag('album'),
      composer: tag('composer'),
      trackNumber: _number(tag('track')),
      discNumber: _number(tag('disc')),
      cover: cover,
    );
  }

  /// Reads the text frames of an ID3v2 tag at the start of the file into [tags]. Returns where the
  /// tag ends, which is where the audio begins and is zero when there is no tag; and, when a cover
  /// was asked for, the picture frame to take it from.
  Future<({int audioStart, _PictureFrame? picture})> _readId3v2(
    Map<String, String> tags,
  ) async {
    const noTag = (audioStart: 0, picture: null);
    final header = await _source.read(0, 10);
    if (header.length < 10 ||
        header[0] != 0x49 || // I
        header[1] != 0x44 || // D
        header[2] != 0x33) {
      // 3
      return noTag;
    }
    final version = header[3];
    final flags = header[5];
    final size = _syncsafe(header, 6);
    if (size == null || version < 2 || version > 4) return noTag;
    final end = 10 + size;
    final tagEnd = end + (version == 4 && flags & 0x10 != 0 ? 10 : 0);
    final unread = (audioStart: tagEnd, picture: null);

    // Unsynchronisation rewrites the tag's bytes, so its frame sizes no longer walk it. It is rare
    // enough that the tags are skipped rather than the rewriting undone.
    if (flags & 0x80 != 0) return unread;

    var p = 10;
    if (version >= 3 && flags & 0x40 != 0) {
      final extended = await _source.read(10, 4);
      if (extended.length < 4) return unread;
      // 2.4 counts the size field itself in the extended header's size; 2.3 does not.
      final extendedSize = version == 4
          ? _syncsafe(extended, 0)
          : ByteData.sublistView(extended).getUint32(0) + 4;
      if (extendedSize == null) return unread;
      p += extendedSize;
    }

    // The front cover if the tag marks one, and otherwise the first picture. Once the front cover
    // is found, later pictures are not looked at.
    _PictureFrame? firstPicture;
    _PictureFrame? frontCover;
    final headerBytes = version == 2 ? 6 : 10;
    while (end - p >= headerBytes) {
      final frameHeader = await _source.read(p, headerBytes);
      // A zero byte where a frame id should be is the start of the tag's padding.
      if (frameHeader.length < headerBytes || frameHeader[0] == 0) break;
      final id = String.fromCharCodes(frameHeader, 0, version == 2 ? 3 : 4);
      final frameSize = switch (version) {
        2 => frameHeader[3] << 16 | frameHeader[4] << 8 | frameHeader[5],
        3 => ByteData.sublistView(frameHeader).getUint32(4),
        _ => _syncsafe(frameHeader, 4),
      };
      if (frameSize == null ||
          frameSize <= 0 ||
          frameSize > end - p - headerBytes) {
        break;
      }

      final key = _frameKeys[id];
      if (key != null && frameSize <= _maxTextBytes) {
        final bodyStart = _bodyStart(version, frameHeader);
        if (bodyStart != null) {
          final body = await _source.read(p + headerBytes, frameSize);
          final value = _text(
            Uint8List.sublistView(body, math.min(bodyStart, body.length)),
          );
          if (value != null) tags.putIfAbsent(key, () => value);
        }
      }
      if (_withCover &&
          frontCover == null &&
          id == (version == 2 ? 'PIC' : 'APIC') &&
          frameSize <= maxPictureBytes) {
        final picture = await _findPicture(
          version,
          frameHeader,
          p + headerBytes,
          frameSize,
        );
        if (picture != null) {
          firstPicture ??= picture;
          if (picture.isFrontCover) frontCover = picture;
        }
      }
      p += headerBytes + frameSize;
    }
    return (audioStart: tagEnd, picture: frontCover ?? firstPicture);
  }

  /// Where a frame's content starts within its body, past the bytes its format flags add, or null
  /// for a frame that cannot be read as it stands: compressed, encrypted, or in 2.4 unsynchronised
  /// frame by frame.
  int? _bodyStart(int version, Uint8List frameHeader) {
    if (version == 2) return 0;
    final format = frameHeader[9];
    if (version == 3) {
      // compression 0x80, encryption 0x40; grouping 0x20 adds a byte.
      if (format & 0xC0 != 0) return null;
      return format & 0x20 != 0 ? 1 : 0;
    }
    // grouping 0x40 adds a byte; compression 0x08, encryption 0x04, unsynchronisation 0x02; a data
    // length indicator 0x01 adds four.
    if (format & 0x0E != 0) return null;
    return (format & 0x40 != 0 ? 1 : 0) + (format & 0x01 != 0 ? 4 : 0);
  }

  /// Locates the image in the picture frame whose body of [size] bytes starts at [offset], reading
  /// only the fields before the image. Null for a frame this reader cannot use.
  Future<_PictureFrame?> _findPicture(
    int version,
    Uint8List frameHeader,
    int offset,
    int size,
  ) async {
    final bodyStart = _bodyStart(version, frameHeader);
    if (bodyStart == null || bodyStart >= size) return null;
    final start = offset + bodyStart;
    final length = size - bodyStart;
    final head = await _source.read(start, math.min(length, _pictureHeadBytes));
    return _PictureFrame.parse(
      head,
      version: version,
      offset: start,
      length: length,
    );
  }

  /// Reads the image [picture] locates. Null when the file ends before the image does, or when its
  /// type can be told from neither its bytes nor its frame.
  Future<EmbeddedPicture?> _readPicture(_PictureFrame picture) async {
    final bytes = await _source.read(picture.offset, picture.length);
    if (bytes.length < picture.length) return null;
    final mimeType = pictureMimeType(bytes, declared: picture.format);
    return mimeType == null
        ? null
        : EmbeddedPicture(mimeType: mimeType, bytes: bytes);
  }

  /// The ID3v1 tag in the last 128 bytes, keyed as the ID3v2 tags are, or null if there is none.
  Future<Map<String, String>?> _readId3v1() async {
    if (_source.length < 128) return null;
    final bytes = await _source.read(_source.length - 128, 128);
    if (bytes.length < 128 ||
        bytes[0] != 0x54 || // T
        bytes[1] != 0x41 || // A
        bytes[2] != 0x47) {
      // G
      return null;
    }
    String? field(int start, int length) {
      final nul = bytes.indexOf(0, start);
      final end = nul < 0 || nul > start + length ? start + length : nul;
      final value = latin1.decode(bytes.sublist(start, end)).trim();
      return value.isEmpty ? null : value;
    }

    return {
      if (field(3, 30) case final title?) 'title': title,
      if (field(33, 30) case final artist?) 'artist': artist,
      if (field(63, 30) case final album?) 'album': album,
      // ID3v1.1 keeps a track number in the comment's last byte, marked by a zero byte before it.
      if (bytes[125] == 0 && bytes[126] != 0) 'track': '${bytes[126]}',
    };
  }

  /// The first Layer III frame at or after [from]. The sync pattern alone also turns up in stray
  /// bytes, so a frame counts only when another frame header follows it, or when it is the last
  /// thing in the file.
  Future<_Frame?> _firstFrame(int from, int audioEnd) async {
    final window = await _source.read(from, _searchBytes);
    for (var i = 0; i + 4 <= window.length && from + i < audioEnd; i++) {
      final frame = _Frame.parse(window, i, from + i);
      if (frame == null) continue;
      final next = frame.offset + frame.length;
      if (next > audioEnd) continue;
      if (next + 4 > audioEnd) return frame;
      final nextHeader = next + 4 <= from + window.length
          ? Uint8List.sublistView(window, next - from, next - from + 4)
          : await _source.read(next, 4);
      final following = _Frame.parse(nextHeader, 0, next);
      if (following != null &&
          following.mpeg1 == frame.mpeg1 &&
          following.sampleRate == frame.sampleRate) {
        return frame;
      }
    }
    return null;
  }

  /// The number of frames a Xing or Info header, or a VBRI header, in [frame] says the file holds.
  Future<int?> _frameCount(_Frame frame) async {
    final xingAt = frame.offset + 4 + (frame.crc ? 2 : 0) + frame.sideInfoBytes;
    if (xingAt + 12 <= frame.offset + frame.length) {
      final xing = await _source.read(xingAt, 12);
      if (xing.length == 12) {
        final id = String.fromCharCodes(xing, 0, 4);
        final view = ByteData.sublistView(xing);
        // Flag 0x1 says the frame count is present.
        if ((id == 'Xing' || id == 'Info') && view.getUint32(4) & 1 != 0) {
          return view.getUint32(8);
        }
      }
    }
    // A VBRI header sits a fixed 32 bytes after the frame header:
    // id(4) version(2) delay(2) quality(2) bytes(4) frames(4).
    if (frame.offset + 36 + 18 <= frame.offset + frame.length) {
      final vbri = await _source.read(frame.offset + 36, 18);
      if (vbri.length == 18 && String.fromCharCodes(vbri, 0, 4) == 'VBRI') {
        return ByteData.sublistView(vbri).getUint32(14);
      }
    }
    return null;
  }
}

/// A 28-bit integer stored seven bits to a byte, as ID3v2 sizes are. Null if a byte has its top
/// bit set, which a real tag never does.
int? _syncsafe(Uint8List bytes, int at) {
  if (bytes.length - at < 4) return null;
  var value = 0;
  for (var i = 0; i < 4; i++) {
    final byte = bytes[at + i];
    if (byte & 0x80 != 0) return null;
    value = value << 7 | byte;
  }
  return value;
}

/// A text frame's value: an encoding byte, then the text in that encoding.
String? _text(Uint8List body) {
  if (body.isEmpty) return null;
  final bytes = Uint8List.sublistView(body, 1);
  final decoded = switch (body[0]) {
    0 => latin1.decode(bytes),
    // UTF-16 with a byte order mark, which the spec requires; big-endian if it is missing.
    1 => _utf16(
      bytes,
      bigEndian: !(bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE),
    ),
    2 => _utf16(bytes, bigEndian: true),
    3 => utf8.decode(bytes, allowMalformed: true),
    _ => null,
  };
  if (decoded == null) return null;
  // A value ends at a null character, and 2.4 separates several values with one. Only the first is
  // kept.
  final nul = decoded.indexOf(' ');
  final value = (nul < 0 ? decoded : decoded.substring(0, nul)).trim();
  return value.isEmpty ? null : value;
}

String _utf16(Uint8List bytes, {required bool bigEndian}) {
  final hasMark =
      bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF));
  return String.fromCharCodes([
    for (var i = hasMark ? 2 : 0; i + 1 < bytes.length; i += 2)
      bigEndian ? bytes[i] << 8 | bytes[i + 1] : bytes[i + 1] << 8 | bytes[i],
  ]);
}

/// Where a string in text encoding [encoding] that starts at [from] in [bytes] ends: just past its
/// null character, which is one zero byte in Latin-1 and UTF-8, and in UTF-16 two zero bytes that
/// make one character. Null when there is none, or the encoding is unknown.
int? _pastNull(Uint8List bytes, int from, int encoding) {
  switch (encoding) {
    case 0 || 3:
      final nul = bytes.indexOf(0, from);
      return nul < 0 ? null : nul + 1;
    case 1 || 2:
      // Stepping a character at a time, so the zero high byte of one character and the zero low
      // byte of the next are not taken for a null character.
      for (var i = from; i + 1 < bytes.length; i += 2) {
        if (bytes[i] == 0 && bytes[i + 1] == 0) return i + 2;
      }
  }
  return null;
}

/// "3" or "3/12" as 3. Null for anything that is not a positive number.
int? _number(String? value) {
  if (value == null) return null;
  final number = int.tryParse(value.split('/').first.trim());
  return number == null || number <= 0 ? null : number;
}
