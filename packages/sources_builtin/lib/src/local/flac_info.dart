/// Tags, duration, cover art and chapters of FLAC files, read in pure Dart.
///
/// Openly licensed audiobooks are often kept as FLAC, the lossless format archives prefer. As for
/// MP3 and MP4 (§3.10), the Timeline needs a file's duration before the audio plugins have loaded
/// it, and a FLAC file states it: STREAMINFO, the metadata block every FLAC file opens with, gives
/// the stream's sample rate and counts its samples. Its tags are Vorbis comments, as Ogg's are, and
/// its cover art is in PICTURE blocks.
///
/// Like the other readers it reads only what it needs through a [ByteSource]: the metadata blocks at
/// the start, and one picture when a cover is asked for, however large the file.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_reading.dart';
import 'embedded_chapter.dart';
import 'embedded_picture.dart';
import 'flac_picture.dart';
import 'mp4_chapters.dart' show ByteSource;
import 'vorbis_comment.dart';

/// What a FLAC file says about itself.
final class FlacInfo {
  const FlacInfo({
    required this.durationMs,
    required this.durationIsEstimate,
    required this.sampleRate,
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

  final int durationMs;

  /// True when STREAMINFO did not count the samples and [durationMs] was worked out from the last
  /// frame instead, as [readFlacInfo] describes. §4.5 then treats it as provisional.
  final bool durationIsEstimate;

  /// In hertz.
  final int sampleRate;

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

  /// The PICTURE block marked as the front cover, or failing that the first. Always null unless
  /// [readFlacInfo] was asked for it.
  final EmbeddedPicture? cover;
}

/// Reads a FLAC file's duration, tags and chapters, and its cover if [withCover] is true.
///
/// Returns null when the file does not open with FLAC's `fLaC` marker. An ID3v2 tag before the
/// marker is skipped, since some taggers add one though FLAC has no place for it; its tags are not
/// read.
///
/// The duration is STREAMINFO's sample count over its sample rate, which is exact. An encoder that
/// cannot go back to the start of what it wrote, as when writing to a pipe, leaves the count at zero,
/// meaning unknown. The duration is then worked out from the file's last frame, found by reading back
/// from the end of the file: its header says where it starts, as a frame or sample number, and how
/// many samples it holds. A header is recognised by its sync code, its checksum and its agreement
/// with STREAMINFO, but audio bytes can still pass for one by chance, so such a duration is marked an
/// estimate, which §4.5 refines once the engine has loaded the file.
///
/// Throws a [FormatException] when the metadata is damaged: truncated, with a block that runs past
/// the end of the file, without STREAMINFO first, with a zero sample rate, with more blocks than any
/// real file has, or with Vorbis comments whose lengths do not fit their block. Also when the sample
/// count is unknown and no frame header can be found near the end of the file.
///
/// The cover is off by default, as for `readMp3Info`: a picture can run to megabytes, and a folder
/// scan probes every file. It is the PICTURE block marked as the front cover, or failing that the
/// first; with no PICTURE block, a `METADATA_BLOCK_PICTURE` comment, which some taggers write into
/// FLAC files too. A picture that cannot be used, as [parseFlacPicture] describes, is no cover.
Future<FlacInfo?> readFlacInfo(ByteSource source, {bool withCover = false}) =>
    _FlacReader(source, withCover: withCover).read();

/// The STREAMINFO block: the stream's sample rate, layout and length.
final class _StreamInfo {
  const _StreamInfo({
    required this.maxBlockSize,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.totalSamples,
  });

  /// Parses the block's first 18 bytes: minimum and maximum block size (2 each), minimum and maximum
  /// frame size (3 each), then 64 bits holding the sample rate (20), channels less one (3), bits per
  /// sample less one (5) and the number of samples (36), zero when unknown.
  factory _StreamInfo.parse(Uint8List bytes, int at) {
    final view = ByteData.sublistView(bytes);
    final packed = view.getUint64(10);
    final sampleRate = (packed >>> 44) & 0xFFFFF;
    if (sampleRate == 0) {
      throw FormatException('STREAMINFO at $at has a zero sample rate');
    }
    return _StreamInfo(
      maxBlockSize: view.getUint16(2),
      sampleRate: sampleRate,
      channels: ((packed >>> 41) & 0x7) + 1,
      bitsPerSample: ((packed >>> 36) & 0x1F) + 1,
      totalSamples: packed & 0xFFFFFFFFF,
    );
  }

  /// Samples in every frame but the last, in a stream of fixed-size blocks.
  final int maxBlockSize;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int totalSamples;
}

/// Where a PICTURE block is, and the picture type it states.
typedef _PictureBlock = ({int offset, int length, int type});

final class _FlacReader {
  _FlacReader(this._source, {required bool withCover}) : _withCover = withCover;

  final ByteSource _source;
  final bool _withCover;

  /// Real files have a handful of metadata blocks, a few more with several pictures. The bound stops
  /// a damaged file from keeping the reader walking millions of empty ones.
  static const _maxBlocks = 1024;

  /// How far back from the end of the file to look for the last frame's header, when STREAMINFO
  /// does not count the samples. Frames of common block sizes run to a few tens of kilobytes.
  static const _tailBytes = 256 * 1024;

  Future<FlacInfo?> read() async {
    final start = await _markerEnd();
    if (start == null) return null;

    _StreamInfo? info;
    ({int start, int end})? comments;
    _PictureBlock? firstPicture;
    _PictureBlock? frontCover;
    var p = start;
    for (var blocks = 0; ; blocks++) {
      if (blocks == _maxBlocks) {
        throw FormatException(
          'FLAC file has more than $_maxBlocks metadata blocks',
        );
      }
      final header = await readExactly(_source, p, 4, what: 'a metadata block');
      final last = header[0] & 0x80 != 0;
      final type = header[0] & 0x7F;
      final length = header[1] << 16 | header[2] << 8 | header[3];
      final body = p + 4;
      if (length > _source.length - body) {
        throw FormatException(
          'FLAC metadata block at $p is $length bytes long, which runs past '
          'the end of the file',
        );
      }
      if (blocks == 0) {
        if (type != 0 || length < 34) {
          throw FormatException(
            'FLAC file does not open with a STREAMINFO block at $p',
          );
        }
        info = _StreamInfo.parse(
          await readExactly(_source, body, 18, what: 'STREAMINFO'),
          body,
        );
      } else {
        switch (type) {
          case 0:
            throw FormatException('FLAC file has a second STREAMINFO at $p');
          case 4 when comments == null:
            comments = (start: body, end: body + length);
          case 6 when _withCover && frontCover == null && length >= 4:
            final pictureType = flacPictureType(
              await readExactly(_source, body, 4, what: 'a picture'),
            )!;
            final picture = (offset: body, length: length, type: pictureType);
            firstPicture ??= picture;
            if (pictureType == frontCoverType) frontCover = picture;
          case 127:
            throw FormatException('FLAC metadata block at $p has type 127');
        }
      }
      p = body + length;
      if (last) break;
    }

    final picture = frontCover ?? firstPicture;
    final tags = comments == null
        ? const VorbisComment()
        : await readVorbisComment(
            _source,
            start: comments.start,
            end: comments.end,
            withCover: _withCover && picture == null,
          );
    final cover = picture == null
        ? tags.cover
        : parseFlacPicture(
            await readExactly(
              _source,
              picture.offset,
              picture.length,
              what: 'a picture',
            ),
          );

    final stream = info!;
    final counted = stream.totalSamples > 0;
    final samples = counted
        ? stream.totalSamples
        : await _samplesToLastFrame(stream, audioStart: p);
    return FlacInfo(
      durationMs: samples * 1000 ~/ stream.sampleRate,
      durationIsEstimate: !counted,
      sampleRate: stream.sampleRate,
      title: tags.title,
      artist: tags.artist,
      albumArtist: tags.albumArtist,
      album: tags.album,
      composer: tags.composer,
      trackNumber: tags.trackNumber,
      discNumber: tags.discNumber,
      chapters: tags.chapters,
      cover: cover,
    );
  }

  /// Where the metadata starts, just past the `fLaC` marker, or null when there is no marker at the
  /// start of the file or just past an ID3v2 tag there.
  Future<int?> _markerEnd() async {
    final head = await _source.read(0, 10);
    if (_isMarker(head)) return 4;
    final tagEnd = id3v2End(head);
    if (tagEnd == null) return null;
    return _isMarker(await _source.read(tagEnd, 4)) ? tagEnd + 4 : null;
  }

  static bool _isMarker(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x66 && // f
      bytes[1] == 0x4C && // L
      bytes[2] == 0x61 && // a
      bytes[3] == 0x43; // C

  /// The number of samples up to the end of the last frame, from its header, for a stream whose
  /// STREAMINFO does not count them. The frames start at [audioStart].
  Future<int> _samplesToLastFrame(
    _StreamInfo stream, {
    required int audioStart,
  }) async {
    final from = math.max(audioStart, _source.length - _tailBytes);
    final tail = await _source.read(from, _source.length - from);
    // The last header is the one nearest the end, so the search runs backwards.
    for (var i = tail.length - 2; i >= 0; i--) {
      if (tail[i] != 0xFF || tail[i + 1] & 0xFE != 0xF8) continue;
      final end = _FrameHeader.endSample(tail, i, stream);
      if (end != null) return end;
    }
    throw FormatException(
      'FLAC file does not count its samples, and no frame header was found '
      'in its last ${_source.length - from} bytes',
    );
  }
}

/// A FLAC frame header, read only to learn where the stream ends.
abstract final class _FrameHeader {
  /// The sample just past the frame whose header starts at [at] in [bytes], or null when the bytes
  /// there are not a frame header of [stream]: an invalid or reserved code, a checksum that does not
  /// match, or a sample rate, channel count or sample size other than STREAMINFO's.
  ///
  /// The header is a sync code of 14 bits, a reserved bit and the blocking strategy (1), the block
  /// size and sample rate codes (4 each), the channel assignment (4), sample size code (3) and a
  /// reserved bit, then the frame's number in a UTF-8-like code: the frame number for fixed-size
  /// blocks, the number of its first sample for variable ones. Then the block size and sample rate
  /// if their codes say they follow, and a CRC-8 of all of it.
  static int? endSample(Uint8List bytes, int at, _StreamInfo stream) {
    if (bytes.length - at < 6) return null;
    final variable = bytes[at + 1] & 1 != 0;
    final blockCode = bytes[at + 2] >> 4;
    final rateCode = bytes[at + 2] & 0xF;
    final channelCode = bytes[at + 3] >> 4;
    final depthCode = (bytes[at + 3] >> 1) & 7;
    if (blockCode == 0 ||
        rateCode == 15 ||
        channelCode > 10 ||
        depthCode == 3 ||
        bytes[at + 3] & 1 != 0) {
      return null;
    }

    var p = at + 4;
    final first = bytes[p++];
    final (int extra, int lead) = switch (first) {
      < 0x80 => (0, first),
      _ when first & 0xE0 == 0xC0 => (1, first & 0x1F),
      _ when first & 0xF0 == 0xE0 => (2, first & 0x0F),
      _ when first & 0xF8 == 0xF0 => (3, first & 0x07),
      _ when first & 0xFC == 0xF8 => (4, first & 0x03),
      _ when first & 0xFE == 0xFC => (5, first & 0x01),
      0xFE => (6, 0),
      _ => (-1, 0),
    };
    // A frame number has at most 31 bits, which take six bytes; a sample number 36, which take seven.
    if (extra < 0 || (!variable && extra > 5)) return null;
    // The rest of the number, the block size and sample rate when they follow, and the checksum.
    final rest =
        extra +
        switch (blockCode) {
          6 => 1,
          7 => 2,
          _ => 0,
        } +
        switch (rateCode) {
          12 => 1,
          13 || 14 => 2,
          _ => 0,
        } +
        1;
    if (bytes.length - p < rest) return null;
    var number = lead;
    for (var i = 0; i < extra; i++) {
      final byte = bytes[p++];
      if (byte & 0xC0 != 0x80) return null;
      number = number << 6 | byte & 0x3F;
    }

    final int blockSize;
    switch (blockCode) {
      case 1:
        blockSize = 192;
      case >= 2 && <= 5:
        blockSize = 576 << (blockCode - 2);
      case 6:
        blockSize = bytes[p++] + 1;
      case 7:
        blockSize = (bytes[p] << 8 | bytes[p + 1]) + 1;
        p += 2;
      default:
        blockSize = 256 << (blockCode - 8);
    }
    final int? sampleRate;
    switch (rateCode) {
      case 0:
        sampleRate = null;
      case 12:
        sampleRate = bytes[p++] * 1000;
      case 13:
        sampleRate = bytes[p] << 8 | bytes[p + 1];
        p += 2;
      case 14:
        sampleRate = (bytes[p] << 8 | bytes[p + 1]) * 10;
        p += 2;
      default:
        sampleRate = _sampleRates[rateCode - 1];
    }
    if (_crc8(bytes, at, p) != bytes[p]) return null;

    final channels = channelCode <= 7 ? channelCode + 1 : 2;
    final bitsPerSample = _sampleSizes[depthCode];
    if ((sampleRate != null && sampleRate != stream.sampleRate) ||
        channels != stream.channels ||
        (bitsPerSample != null && bitsPerSample != stream.bitsPerSample) ||
        (stream.maxBlockSize > 0 && blockSize > stream.maxBlockSize)) {
      return null;
    }
    if (variable) return number + blockSize;
    // Every frame before the last holds a full block.
    if (stream.maxBlockSize == 0) return null;
    return number * stream.maxBlockSize + blockSize;
  }

  /// Sample rates by code, from code 1. Code 0 means STREAMINFO's; codes 12 to 14 are followed by the
  /// rate itself.
  static const _sampleRates = [
    88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, //
    96000,
  ];

  /// Bits per sample by code. Code 0 means STREAMINFO's, and code 3 is reserved.
  static const _sampleSizes = [null, 8, 12, null, 16, 20, 24, 32];

  /// FLAC's CRC-8, polynomial x^8 + x^2 + x + 1, of [bytes] from [start] to [end].
  static int _crc8(Uint8List bytes, int start, int end) {
    var crc = 0;
    for (var i = start; i < end; i++) {
      crc = _crc8Table[crc ^ bytes[i]];
    }
    return crc;
  }

  static final _crc8Table = () {
    final table = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      var crc = i;
      for (var bit = 0; bit < 8; bit++) {
        crc = crc & 0x80 != 0 ? (crc << 1 ^ 0x07) & 0xFF : crc << 1 & 0xFF;
      }
      table[i] = crc;
    }
    return table;
  }();
}
