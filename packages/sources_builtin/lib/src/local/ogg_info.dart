/// Tags, duration, cover art and chapters of Ogg Vorbis and Ogg Opus files, read in pure Dart.
///
/// Many openly licensed audiobooks are published as Ogg Vorbis, and newer ones as Opus. Ogg is a
/// container of pages, each carrying pieces of the packets of one logical stream. A Vorbis or Opus
/// stream opens with its header packets: an identification header, alone on the first page, which
/// names the codec and its sample rate; then a comment header of Vorbis comments, which holds the
/// tags, the chapters and any cover art, and which spreads over many pages when it holds a picture.
///
/// Nothing in the headers says how long the stream is. Every page does carry a granule position,
/// which for both codecs counts the samples decoded by the end of the page, so the duration comes
/// from the last page, found by reading back from the end of the file.
///
/// Like the other readers it reads only what it needs through a [ByteSource]: the header pages, the
/// last page or two, and one picture when a cover is asked for, however large the file.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_reading.dart';
import 'embedded_chapter.dart';
import 'embedded_picture.dart';
import 'mp4_chapters.dart' show ByteSource;
import 'vorbis_comment.dart';

/// The codecs read from Ogg files.
enum OggCodec { vorbis, opus }

/// What an Ogg Vorbis or Ogg Opus file says about itself.
final class OggInfo {
  const OggInfo({
    required this.codec,
    required this.durationMs,
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

  /// As the stream's identification header names it, whatever the file's extension says.
  final OggCodec codec;

  /// From the last page's granule position, so exact rather than estimated.
  final int durationMs;

  /// `TITLE`: in a book's folder, usually the chapter's title.
  final String? title;

  /// `ARTIST`, conventionally the author.
  final String? artist;

  /// `ALBUMARTIST`, which some taggers use for the author instead.
  final String? albumArtist;

  /// `ALBUM`: in a book's folder, usually the book's title.
  final String? album;

  /// `COMPOSER`, which audiobook taggers commonly use for the narrator.
  final String? composer;

  /// `TRACKNUMBER`, without any "of" count.
  final int? trackNumber;

  /// `DISCNUMBER`, without any "of" count.
  final int? discNumber;

  /// From `CHAPTERnnn` comments, in order of their start.
  final List<EmbeddedChapter> chapters;

  /// From a `METADATA_BLOCK_PICTURE` comment: the picture marked as the front cover, or failing that
  /// the first. Always null unless [readOggInfo] was asked for it.
  final EmbeddedPicture? cover;
}

/// Reads an Ogg Vorbis or Ogg Opus file's duration, tags and chapters, and its cover if [withCover]
/// is true.
///
/// Returns null when the file does not open with an Ogg page, or when its stream is in a codec other
/// than Vorbis or Opus, such as FLAC or Speex in Ogg.
///
/// The duration is the last page's granule position over the sample rate. For Vorbis that is the
/// rate its identification header states. Opus always counts at 48 kHz, whatever rate the audio was
/// made at, and its stream starts with pre-skip samples that the decoder discards, so those are
/// taken off.
///
/// Throws a [FormatException] when the file is damaged: truncated before its headers end, with a
/// first page that fails its checksum, with headers that are not what their codec requires, with a
/// comment header larger than any real one or whose lengths do not fit it, or with no page near the
/// end that says where the stream ends. A file cut short in its audio is not refused: its duration is
/// that of its last whole page, which is as far as it plays.
///
/// Also throws a [FormatException] for a file holding more than one logical stream, whether
/// multiplexed, as audio beside a video or a Skeleton index is, or chained, one stream after another.
/// The last page's granule position would give the duration of only the stream it belongs to, and
/// timing the whole file would take reading every page of it.
///
/// The cover is off by default, as for `readMp3Info`: a picture can run to megabytes, and a folder
/// scan probes every file.
Future<OggInfo?> readOggInfo(ByteSource source, {bool withCover = false}) =>
    _OggReader(source, withCover: withCover).read();

/// One Ogg page's header: the capture pattern `OggS`, version (1), header type (1), granule position
/// (8), stream serial number (4), page sequence number (4), CRC (4) and number of segments (1), all
/// little-endian, then that many lacing values, the lengths of the page's segments.
final class _Page {
  const _Page({
    required this.offset,
    required this.flags,
    required this.granule,
    required this.serial,
    required this.lacing,
  });

  /// Parses the page header at [at] in [bytes], a page at [offset] in the file. Null when the bytes
  /// there are not a page header, or end before its lacing values do.
  static _Page? parse(Uint8List bytes, int at, int offset) {
    if (bytes.length - at < headerBytes ||
        !_startsWith(bytes, _capture, at: at) ||
        bytes[at + 4] != 0) {
      return null;
    }
    final segments = bytes[at + 26];
    if (bytes.length - at < headerBytes + segments) return null;
    final view = ByteData.sublistView(bytes);
    return _Page(
      offset: offset,
      flags: bytes[at + 5],
      granule: view.getInt64(at + 6, Endian.little),
      serial: view.getUint32(at + 14, Endian.little),
      lacing: Uint8List.sublistView(
        bytes,
        at + headerBytes,
        at + headerBytes + segments,
      ),
    );
  }

  /// The fixed part of a page header, before the lacing values.
  static const headerBytes = 27;

  static const _capture = [0x4F, 0x67, 0x67, 0x53]; // OggS

  /// Where the page starts in the file.
  final int offset;
  final int flags;

  /// The samples decoded by the end of the last packet that ends on this page, or -1 when none does.
  final int granule;
  final int serial;
  final Uint8List lacing;

  /// The page carries on a packet from the page before.
  bool get continued => flags & 0x01 != 0;

  /// The first page of a logical stream.
  bool get beginsStream => flags & 0x02 != 0;

  int get headerLength => headerBytes + lacing.length;
  int get length => headerLength + lacing.fold(0, (sum, lace) => sum + lace);
  int get end => offset + length;

  /// Whether the page, whole in [bytes] at [at], carries the checksum of its contents: Ogg's CRC-32,
  /// polynomial 0x04C11DB7 unreflected, computed with the checksum field as zeros.
  bool checksumMatches(Uint8List bytes, int at) {
    var crc = 0;
    for (var i = 0; i < length; i++) {
      final byte = i >= 22 && i < 26 ? 0 : bytes[at + i];
      crc = (crc << 8 & 0xFFFFFFFF) ^ _crcTable[(crc >> 24) ^ byte];
    }
    return crc == ByteData.sublistView(bytes).getUint32(at + 22, Endian.little);
  }

  static final _crcTable = () {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var crc = i << 24;
      for (var bit = 0; bit < 8; bit++) {
        crc = crc & 0x80000000 != 0
            ? (crc << 1 ^ 0x04C11DB7) & 0xFFFFFFFF
            : crc << 1 & 0xFFFFFFFF;
      }
      table[i] = crc;
    }
    return table;
  }();
}

/// What a stream's identification header says.
typedef _Stream = ({OggCodec codec, int sampleRate, int preSkip});

final class _OggReader {
  _OggReader(this._source, {required bool withCover}) : _withCover = withCover;

  final ByteSource _source;
  final bool _withCover;

  /// The largest page there can be: its header, 255 lacing values, and 255 segments of 255 bytes.
  static const _maxPageBytes = _Page.headerBytes + 255 + 255 * 255;

  /// How much of the end of the file is searched for the last page: enough for the last two pages
  /// of the largest size, since the very last may be cut short or end no packet.
  static const _tailBytes = 2 * _maxPageBytes;

  /// No comment header is remotely this large, even with a picture of [maxPictureBytes] in base64.
  /// The bound, and the one on the pages it spans, stop a damaged file from keeping the reader
  /// walking pages to its end.
  static const _maxCommentBytes = 32 * 1024 * 1024;
  static const _maxCommentPages = 4096;

  /// Granule positions beyond this are taken as damage: at 48 kHz it is over 185 years, and the
  /// bound keeps the arithmetic on them exact.
  static const _maxGranule = 1 << 48;

  static const _vorbisId = [
    0x01,
    0x76,
    0x6F,
    0x72,
    0x62,
    0x69,
    0x73,
  ]; // 1vorbis
  static const _vorbisComment = [0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73];
  static const _opusId = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64];
  static const _opusComment = [0x4F, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73];

  Future<OggInfo?> read() async {
    if (!_startsWith(await _source.read(0, 4), _Page._capture)) return null;
    final first = await _pageAt(0);
    final opening = await readExactly(
      _source,
      0,
      first.length,
      what: 'the first Ogg page',
    );
    final stream = _identify(
      Uint8List.sublistView(opening, first.headerLength),
    );
    if (stream == null) return null;
    if (!first.checksumMatches(opening, 0)) {
      throw const FormatException('first Ogg page fails its checksum');
    }
    // The identification header must stand alone on the first page: one packet, which ends there.
    final lacing = first.lacing;
    if (!first.beginsStream ||
        first.continued ||
        lacing.isEmpty ||
        lacing.last == 255 ||
        lacing.take(lacing.length - 1).any((lace) => lace != 255)) {
      throw const FormatException(
        'first Ogg page does not hold an identification header alone',
      );
    }

    final comments = await _secondPacket(first);
    final magic = switch (stream.codec) {
      OggCodec.vorbis => _vorbisComment,
      OggCodec.opus => _opusComment,
    };
    if (!_startsWith(await comments.read(0, magic.length), magic)) {
      throw FormatException(
        'second packet of the Ogg ${stream.codec.name} stream is not its '
        'comment header',
      );
    }
    final tags = await readVorbisComment(
      comments,
      start: magic.length,
      end: comments.length,
      withCover: _withCover,
    );

    final samples = await _lastGranule(first.serial) - stream.preSkip;
    if (samples <= 0) {
      throw const FormatException('Ogg stream holds no audio');
    }
    return OggInfo(
      codec: stream.codec,
      durationMs: samples * 1000 ~/ stream.sampleRate,
      title: tags.title,
      artist: tags.artist,
      albumArtist: tags.albumArtist,
      album: tags.album,
      composer: tags.composer,
      trackNumber: tags.trackNumber,
      discNumber: tags.discNumber,
      chapters: tags.chapters,
      cover: tags.cover,
    );
  }

  /// What the identification header at the start of [packet] says, or null when it names neither
  /// codec.
  ///
  /// Vorbis: packet type 1 and `vorbis`, version (4), channels (1), sample rate (4), three bitrates
  /// (4 each), block sizes (1) and a framing bit, 30 bytes in all. Opus: `OpusHead`, version (1),
  /// channels (1), pre-skip (2), the input's sample rate (4), output gain (2) and channel mapping
  /// family (1), at least 19 bytes. Both little-endian.
  static _Stream? _identify(Uint8List packet) {
    final view = ByteData.sublistView(packet);
    if (_startsWith(packet, _vorbisId)) {
      if (packet.length < 30 ||
          view.getUint32(7, Endian.little) != 0 ||
          packet[11] == 0 ||
          view.getUint32(12, Endian.little) == 0 ||
          packet[29] & 1 == 0) {
        throw const FormatException(
          'Vorbis identification header is not valid',
        );
      }
      return (
        codec: OggCodec.vorbis,
        sampleRate: view.getUint32(12, Endian.little),
        preSkip: 0,
      );
    }
    if (_startsWith(packet, _opusId)) {
      // Versions 0 to 15 share a layout; a new major version in the top four bits would not.
      if (packet.length < 19 || packet[8] >> 4 != 0 || packet[9] == 0) {
        throw const FormatException('Opus identification header is not valid');
      }
      return (
        codec: OggCodec.opus,
        sampleRate: 48000,
        preSkip: view.getUint16(10, Endian.little),
      );
    }
    return null;
  }

  /// The stream's second packet, its comment header, which starts on the second page and may run on
  /// over many more. Only the pages' headers are read here; the packet itself is read later, and
  /// only as far as it is needed.
  Future<_Packet> _secondPacket(_Page first) async {
    final parts = <({int offset, int length})>[];
    var length = 0;
    var offset = first.end;
    for (var pages = 0; ; pages++) {
      if (pages == _maxCommentPages) {
        throw const FormatException(
          'Ogg comment header runs over more pages than any real one',
        );
      }
      final page = await _pageAt(offset);
      if (page.serial != first.serial || page.beginsStream) {
        throw const FormatException(
          'Ogg file holds several logical streams multiplexed together, '
          'which cannot be timed',
        );
      }
      if (page.continued != (pages > 0)) {
        throw FormatException(
          'Ogg page at $offset breaks off the comment header',
        );
      }
      // The packet runs on through segments of 255 bytes, and ends with the first shorter one.
      var run = 0;
      var ended = false;
      for (final lace in page.lacing) {
        run += lace;
        if (lace < 255) {
          ended = true;
          break;
        }
      }
      if (run > 0) {
        parts.add((offset: page.offset + page.headerLength, length: run));
      }
      length += run;
      if (length > _maxCommentBytes) {
        throw const FormatException(
          'Ogg comment header is larger than any real one',
        );
      }
      if (ended) return _Packet(_source, parts, length);
      offset = page.end;
    }
  }

  /// The page at [offset]: its header and lacing values, checked to be a page and to end within the
  /// file.
  Future<_Page> _pageAt(int offset) async {
    final bytes = await _source.read(offset, _Page.headerBytes + 255);
    final page = _Page.parse(bytes, 0, offset);
    if (page == null) {
      throw FormatException(
        bytes.length < _Page.headerBytes
            ? 'Ogg file ends at ${_source.length}, where a page should start'
            : 'no Ogg page at $offset, where one should start',
      );
    }
    if (page.length > _source.length - offset) {
      throw FormatException(
        'Ogg page at $offset runs past the end of the file',
      );
    }
    return page;
  }

  /// The granule position of the last page that has one, found by searching back from the end of
  /// the file for a page whose checksum matches. The search passes over a last page that is cut
  /// short, and over pages on which no packet ends.
  Future<int> _lastGranule(int serial) async {
    final from = math.max(0, _source.length - _tailBytes);
    final tail = await _source.read(from, _source.length - from);
    for (var i = tail.length - _Page.headerBytes; i >= 0; i--) {
      final page = _Page.parse(tail, i, from + i);
      if (page == null ||
          page.length > tail.length - i ||
          !page.checksumMatches(tail, i)) {
        continue;
      }
      if (page.serial != serial) {
        throw const FormatException(
          'Ogg file holds more than one logical stream, chained or '
          'multiplexed, which cannot be timed',
        );
      }
      if (page.granule == -1) continue;
      if (page.granule < 0 || page.granule > _maxGranule) {
        throw FormatException(
          'Ogg page at ${page.offset} has an impossible granule position',
        );
      }
      return page.granule;
    }
    throw FormatException(
      'no Ogg page in the last ${tail.length} bytes of the file says where '
      'the stream ends',
    );
  }
}

/// Whether [bytes] hold [magic] at [at].
bool _startsWith(Uint8List bytes, List<int> magic, {int at = 0}) {
  if (bytes.length - at < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[at + i] != magic[i]) return false;
  }
  return true;
}

/// A packet that spans pages, read as if its bytes were one run. [_parts] are the runs of the file
/// it is made of, in order.
final class _Packet implements ByteSource {
  _Packet(this._file, this._parts, this.length);

  final ByteSource _file;
  final List<({int offset, int length})> _parts;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    // Separate statements, so that `math.max` infers `int` rather than the `num` an inline sum would
    // give it as context, as in `MemoryByteSource.read`.
    final start = math.max(offset, 0);
    final available = math.max(count, 0);
    final end = math.min(start + available, length);
    final out = BytesBuilder(copy: false);
    var partStart = 0;
    for (final part in _parts) {
      if (partStart >= end) break;
      final partEnd = partStart + part.length;
      if (partEnd > start) {
        final from = math.max(start, partStart);
        final to = math.min(end, partEnd);
        out.add(
          await readExactly(
            _file,
            part.offset + from - partStart,
            to - from,
            what: 'the Ogg comment header',
          ),
        );
      }
      partStart = partEnd;
    }
    return out.takeBytes();
  }
}
