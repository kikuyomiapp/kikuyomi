/// Embedded chapter markers in MP4 and M4B files.
///
/// docs/architecture.md §1.5 lists "one large file with embedded chapter markers" as one of the four
/// layouts the Timeline must represent, and those markers have to be read out of the file. Spike (d)
/// proved this works in pure Dart, with no platform plugin and no ffmpeg at runtime. This is the
/// production version of that spike, with the gaps it recorded closed: `largesize` boxes, 64-bit
/// chunk offsets, UTF-8 titles, and bounds on everything a damaged file could claim.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Random access to bytes.
///
/// The reader never holds a file in memory. Real audiobooks reach a gigabyte, and a whole-file read
/// on a phone would be an out-of-memory crash; walking the box tree instead costs a few hundred
/// bytes however large the audio is. The interface also lets tests build files shaped like ones
/// over 4 GB without writing 4 GB.
abstract interface class ByteSource {
  /// Total length in bytes.
  int get length;

  /// Reads up to [count] bytes from [offset]. May return fewer at the end of the source.
  Future<Uint8List> read(int offset, int count);
}

/// A file on disk.
final class FileByteSource implements ByteSource {
  FileByteSource._(this._file, this.length);

  /// Opens [file]. Call [close] when finished.
  static Future<FileByteSource> open(File file) async {
    final handle = await file.open();
    return FileByteSource._(handle, await handle.length());
  }

  final RandomAccessFile _file;

  @override
  final int length;

  /// Reads must not overlap: a `RandomAccessFile` rejects a second asynchronous operation while one
  /// is pending. The chapter reader awaits every read, so it never overlaps them.
  @override
  Future<Uint8List> read(int offset, int count) async {
    await _file.setPosition(offset);
    return _file.read(count);
  }

  Future<void> close() => _file.close();
}

/// Bytes already in memory.
final class MemoryByteSource implements ByteSource {
  MemoryByteSource(this._bytes);

  final Uint8List _bytes;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    // Kept as separate statements on purpose. Inline, `int.operator +` supplies `num` as the context
    // for `math.max`, which then infers `num` and makes `end` a `num`.
    final start = math.min(math.max(offset, 0), _bytes.length);
    final available = math.max(count, 0);
    final end = math.min(start + available, _bytes.length);
    return Uint8List.sublistView(_bytes, start, end);
  }
}

/// Where a file's chapters were found.
enum Mp4ChapterFormat {
  /// Nero's `chpl` atom, written by ffmpeg and most taggers.
  nero,

  /// A QuickTime chapter track, which is the only format Apple's own tools write.
  quickTime,
}

/// One embedded chapter marker.
final class Mp4Chapter {
  const Mp4Chapter({required this.startMs, required this.title});

  /// Offset into the file.
  final int startMs;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is Mp4Chapter && other.startMs == startMs && other.title == title;

  @override
  int get hashCode => Object.hash(startMs, title);

  @override
  String toString() => 'Mp4Chapter(${startMs}ms, "$title")';
}

/// The chapters found in a file, and which format they came from.
final class Mp4Chapters {
  const Mp4Chapters({required this.format, required this.chapters});

  final Mp4ChapterFormat format;
  final List<Mp4Chapter> chapters;
}

/// Reads the embedded chapters from an MP4 or M4B.
///
/// Returns null when the file carries chapters in neither format. Callers should treat that as a
/// book with one chapter, not as an error.
///
/// When a file carries both formats, the `chpl` atom wins. Spike (d) found them in agreement in
/// every file examined, so the choice rests on `chpl` being cheaper to read rather than on evidence
/// that either is more trustworthy.
///
/// Throws [FormatException] when the file is structurally damaged: truncated, with a box whose size
/// does not fit inside its parent, or with a chapter table larger than any real one could be. A
/// damaged file is reported rather than silently treated as having no chapters. Sample tables whose
/// counts disagree with each other are tolerated by reading the shortest, since that happens in
/// files which otherwise play correctly.
///
/// Not handled: edit lists that offset the chapter track's start, and chapter titles in encodings
/// other than UTF-8.
Future<Mp4Chapters?> readMp4Chapters(ByteSource source) =>
    _Mp4Reader(source).read();

/// What an MP4 or M4B file says about itself: enough to import it as a book.
final class Mp4Info {
  const Mp4Info({
    required this.durationMs,
    this.title,
    this.artist,
    this.album,
    this.composer,
    this.chapters,
  });

  /// From the movie header, so exact rather than estimated.
  final int durationMs;

  /// `©nam`. Usually the book's title, though some taggers put that in [album] instead.
  final String? title;

  /// `©ART`, conventionally the author.
  final String? artist;

  /// `©alb`.
  final String? album;

  /// `©wrt`, which audiobook taggers commonly use for the narrator.
  final String? composer;

  final Mp4Chapters? chapters;
}

/// Reads a file's duration, its common text tags and its chapters.
///
/// Returns null when the bytes hold no movie box at all. Throws [FormatException] for a damaged
/// file, as [readMp4Chapters] does, and also when the movie header is missing or has a zero
/// timescale, since a book with no duration cannot be played.
Future<Mp4Info?> readMp4Info(ByteSource source) =>
    _Mp4Reader(source).readInfo();

final class _Box {
  const _Box({
    required this.type,
    required this.start,
    required this.headerSize,
    required this.size,
  });

  final String type;
  final int start;

  /// 8 normally, 16 when the size is a 64-bit `largesize`.
  final int headerSize;

  /// Total size, header included.
  final int size;

  int get contentStart => start + headerSize;
  int get contentLength => size - headerSize;
  int get end => start + size;
}

final class _Mp4Reader {
  _Mp4Reader(this._source);

  final ByteSource _source;

  /// No chapter table is remotely this large. The bound exists so that a damaged or hostile file
  /// claiming a multi-gigabyte table fails fast instead of allocating it.
  static const _maxTableBytes = 16 * 1024 * 1024;

  /// Likewise for the number of chapters a table may expand to.
  static const _maxChapters = 10000;

  /// Tag values larger than this are skipped. Titles and names are tiny; the bound only stops a
  /// damaged file claiming a huge one.
  static const _maxTagBytes = 64 * 1024;

  Future<Mp4Chapters?> read() async {
    final moov = await _findChild('moov', 0, _source.length);
    if (moov == null) return null;
    return _chaptersIn(moov);
  }

  Future<Mp4Info?> readInfo() async {
    final moov = await _findChild('moov', 0, _source.length);
    if (moov == null) return null;

    final mvhd = await _findChild('mvhd', moov.contentStart, moov.end);
    if (mvhd == null) {
      throw FormatException('movie box at ${moov.start} has no movie header');
    }
    // version 0: creation(4) modification(4) timescale(4) duration(4)
    // version 1: creation(8) modification(8) timescale(4) duration(8)
    final version = await _version(mvhd);
    final timescale = await _u32At(mvhd, version == 1 ? 20 : 12);
    if (timescale == 0) {
      throw FormatException(
        'movie header at ${mvhd.start} has a zero timescale',
      );
    }
    final duration = version == 1
        ? await _u64At(mvhd, 24)
        : await _u32At(mvhd, 16);
    if (duration < 0) {
      throw FormatException(
        'movie header at ${mvhd.start} has an impossible duration',
      );
    }

    final tags = await _readTags(moov);
    return Mp4Info(
      durationMs: duration * 1000 ~/ timescale,
      title: tags['©nam'],
      artist: tags['©ART'],
      album: tags['©alb'],
      composer: tags['©wrt'],
      chapters: await _chaptersIn(moov),
    );
  }

  Future<Mp4Chapters?> _chaptersIn(_Box moov) async {
    final nero = await _readChpl(moov);
    if (nero != null && nero.isNotEmpty) {
      return Mp4Chapters(format: Mp4ChapterFormat.nero, chapters: nero);
    }
    final quickTime = await _readChapterTrack(moov);
    if (quickTime != null && quickTime.isNotEmpty) {
      return Mp4Chapters(
        format: Mp4ChapterFormat.quickTime,
        chapters: quickTime,
      );
    }
    return null;
  }

  // Box tree.

  Future<Uint8List> _bytes(int offset, int count) async {
    final bytes = await _source.read(offset, count);
    if (bytes.length != count) {
      throw FormatException(
        'unexpected end of file reading $count bytes at offset $offset',
      );
    }
    return bytes;
  }

  Future<_Box> _boxAt(int offset, int parentEnd) async {
    final header = await _bytes(offset, 8);
    final type = String.fromCharCodes(header, 4, 8);
    var size = ByteData.sublistView(header).getUint32(0);
    var headerSize = 8;
    if (size == 1) {
      if (parentEnd - offset < 16) {
        throw FormatException('box "$type" at $offset is truncated');
      }
      size = ByteData.sublistView(await _bytes(offset + 8, 8)).getUint64(0);
      headerSize = 16;
    } else if (size == 0) {
      size = parentEnd - offset;
    }
    // Compared as a remaining length rather than an end offset, so an enormous size cannot overflow.
    // A 64-bit size with its top bit set reads as negative and fails the first test.
    if (size < headerSize || size > parentEnd - offset) {
      throw FormatException(
        'box "$type" at $offset has size $size, which does not fit inside its '
        'parent',
      );
    }
    return _Box(type: type, start: offset, headerSize: headerSize, size: size);
  }

  Future<_Box?> _findChild(String type, int from, int to) async {
    var offset = from;
    while (to - offset >= 8) {
      final box = await _boxAt(offset, to);
      if (box.type == type) return box;
      offset = box.end;
    }
    return null;
  }

  Future<_Box?> _find(List<String> path, _Box parent) async {
    var current = parent;
    for (final type in path) {
      final child = await _findChild(type, current.contentStart, current.end);
      if (child == null) return null;
      current = child;
    }
    return current;
  }

  Future<List<_Box>> _children(_Box parent) async {
    final boxes = <_Box>[];
    var offset = parent.contentStart;
    while (parent.end - offset >= 8) {
      final box = await _boxAt(offset, parent.end);
      boxes.add(box);
      offset = box.end;
    }
    return boxes;
  }

  Future<Uint8List> _content(_Box box) {
    if (box.contentLength > _maxTableBytes) {
      throw FormatException(
        '"${box.type}" at ${box.start} claims ${box.contentLength} bytes, more than '
        'any chapter table holds',
      );
    }
    return _bytes(box.contentStart, box.contentLength);
  }

  /// Reads a field at [at] bytes into [box], after its version-and-flags word.
  Future<int> _u32At(_Box box, int at) async {
    if (box.contentLength < at + 4) {
      throw FormatException('"${box.type}" at ${box.start} is truncated');
    }
    return ByteData.sublistView(await _bytes(box.contentStart + at, 4))
        .getUint32(0);
  }

  Future<int> _u64At(_Box box, int at) async {
    if (box.contentLength < at + 8) {
      throw FormatException('"${box.type}" at ${box.start} is truncated');
    }
    return ByteData.sublistView(await _bytes(box.contentStart + at, 8))
        .getUint64(0);
  }

  // iTunes-style tags.

  /// Text items under `moov/udta/meta/ilst`, keyed by item type such as `©nam`. Only UTF-8 text
  /// values are read; cover art and numeric items are skipped.
  Future<Map<String, String>> _readTags(_Box moov) async {
    final meta = await _find(const ['udta', 'meta'], moov);
    if (meta == null) return const {};

    // ISO files make `meta` a full box, with four bytes of version and flags before its children;
    // QuickTime files do not. The first child is always `hdlr`, which tells the two apart.
    var childrenStart = meta.contentStart;
    if (meta.contentLength >= 8) {
      final probe = await _bytes(meta.contentStart + 4, 4);
      if (String.fromCharCodes(probe) != 'hdlr') childrenStart += 4;
    }
    final ilst = await _findChild('ilst', childrenStart, meta.end);
    if (ilst == null) return const {};

    final tags = <String, String>{};
    var offset = ilst.contentStart;
    while (ilst.end - offset >= 8) {
      final item = await _boxAt(offset, ilst.end);
      offset = item.end;
      final data = await _findChild('data', item.contentStart, item.end);
      if (data == null || data.contentLength < 8) continue;
      // type indicator(4): the low three bytes say what the value is, and 1 means UTF-8 text.
      // locale(4) follows, then the value.
      if (await _u32At(data, 0) & 0x00FFFFFF != 1) continue;
      final length = data.contentLength - 8;
      if (length > _maxTagBytes) continue;
      tags[item.type] = utf8.decode(
        await _bytes(data.contentStart + 8, length),
        allowMalformed: true,
      );
    }
    return tags;
  }

  // Nero chpl.

  /// Layout, decoded by hand in spike (d) from a file ffmpeg wrote:
  /// `version(1) flags(3) [reserved(4) when version is 1] count(1)`, then per chapter
  /// `start(8, in 100-nanosecond units) titleLength(1) title`.
  Future<List<Mp4Chapter>?> _readChpl(_Box moov) async {
    final chpl = await _find(const ['udta', 'chpl'], moov);
    if (chpl == null) return null;
    final body = await _content(chpl);
    final view = ByteData.sublistView(body);

    FormatException truncated() =>
        FormatException('chpl atom at ${chpl.start} is truncated');

    if (body.length < 5) throw truncated();
    var p = body[0] == 1 ? 8 : 4;
    if (p >= body.length) throw truncated();
    final count = body[p++];

    final chapters = <Mp4Chapter>[];
    for (var i = 0; i < count; i++) {
      if (body.length - p < 9) throw truncated();
      final ticks = view.getUint64(p);
      p += 8;
      final titleLength = body[p++];
      if (ticks < 0 || body.length - p < titleLength) throw truncated();
      chapters.add(
        Mp4Chapter(
          startMs: ticks ~/ 10000,
          title: utf8.decode(
            body.sublist(p, p + titleLength),
            allowMalformed: true,
          ),
        ),
      );
      p += titleLength;
    }
    return chapters;
  }

  // QuickTime chapter track.

  Future<List<Mp4Chapter>?> _readChapterTrack(_Box moov) async {
    final traks = [
      for (final box in await _children(moov))
        if (box.type == 'trak') box,
    ];
    if (traks.isEmpty) return null;

    int? chapterTrackId;
    for (final trak in traks) {
      final chap = await _find(const ['tref', 'chap'], trak);
      if (chap != null && chap.contentLength >= 4) {
        chapterTrackId = ByteData.sublistView(
          await _bytes(chap.contentStart, 4),
        ).getUint32(0);
        break;
      }
    }
    if (chapterTrackId == null) return null;

    _Box? track;
    for (final trak in traks) {
      final tkhd = await _findChild('tkhd', trak.contentStart, trak.end);
      if (tkhd != null && await _trackId(tkhd) == chapterTrackId) {
        track = trak;
        break;
      }
    }
    // Some writers leave track ids unset. A text track is then the only reasonable candidate; the
    // audio track never is, however the ids read.
    if (track == null) {
      for (final trak in traks) {
        final handler = await _handler(trak);
        if (handler == 'text' || handler == 'sbtl') {
          track = trak;
          break;
        }
      }
    }
    if (track == null) return null;

    final mdhd = await _find(const ['mdia', 'mdhd'], track);
    final stbl = await _find(const ['mdia', 'minf', 'stbl'], track);
    if (mdhd == null || stbl == null) {
      throw FormatException(
        'chapter track at ${track.start} has no media header or sample table',
      );
    }
    final timescale = await _u32At(mdhd, await _version(mdhd) == 1 ? 20 : 12);
    if (timescale == 0) {
      throw FormatException(
        'chapter track at ${track.start} has a zero timescale',
      );
    }

    final durations = await _sampleDurations(stbl);
    final sizes = await _sampleSizes(stbl);
    final offsets = await _sampleOffsets(stbl, sizes);
    final count = [
      durations.length,
      sizes.length,
      offsets.length,
    ].reduce(math.min);

    final chapters = <Mp4Chapter>[];
    var elapsed = 0;
    for (var i = 0; i < count; i++) {
      chapters.add(
        Mp4Chapter(
          startMs: elapsed * 1000 ~/ timescale,
          title: await _textSample(offsets[i], sizes[i]),
        ),
      );
      elapsed += durations[i];
    }
    return chapters;
  }

  Future<int> _version(_Box box) async {
    if (box.contentLength < 4) {
      throw FormatException('"${box.type}" at ${box.start} is truncated');
    }
    return (await _bytes(box.contentStart, 1))[0];
  }

  Future<int> _trackId(_Box tkhd) async =>
      _u32At(tkhd, await _version(tkhd) == 1 ? 20 : 12);

  Future<String?> _handler(_Box trak) async {
    final hdlr = await _find(const ['mdia', 'hdlr'], trak);
    if (hdlr == null || hdlr.contentLength < 12) return null;
    return String.fromCharCodes(await _bytes(hdlr.contentStart + 8, 4));
  }

  Future<_Box> _table(_Box stbl, String type) async {
    final box = await _findChild(type, stbl.contentStart, stbl.end);
    if (box == null) {
      throw FormatException('sample table at ${stbl.start} has no "$type"');
    }
    return box;
  }

  FormatException _tooMany(_Box box) => FormatException(
    '"${box.type}" at ${box.start} describes more than $_maxChapters chapters',
  );

  FormatException _truncatedTable(_Box box) =>
      FormatException('"${box.type}" at ${box.start} is truncated');

  /// `stts` is run-length encoded as (sampleCount, sampleDelta) pairs.
  Future<List<int>> _sampleDurations(_Box stbl) async {
    final box = await _table(stbl, 'stts');
    final body = await _content(box);
    if (body.length < 8) throw _truncatedTable(box);
    final view = ByteData.sublistView(body);
    final entries = view.getUint32(4);
    if ((body.length - 8) ~/ 8 < entries) throw _truncatedTable(box);

    final durations = <int>[];
    for (var i = 0; i < entries; i++) {
      final samples = view.getUint32(8 + i * 8);
      final delta = view.getUint32(12 + i * 8);
      if (samples > _maxChapters - durations.length) throw _tooMany(box);
      durations.addAll(List.filled(samples, delta));
    }
    return durations;
  }

  /// `stsz` gives either one size for every sample or a size per sample.
  Future<List<int>> _sampleSizes(_Box stbl) async {
    final box = await _table(stbl, 'stsz');
    final body = await _content(box);
    if (body.length < 12) throw _truncatedTable(box);
    final view = ByteData.sublistView(body);
    final uniform = view.getUint32(4);
    final count = view.getUint32(8);
    if (count > _maxChapters) throw _tooMany(box);
    if (uniform != 0) return List.filled(count, uniform);
    if ((body.length - 12) ~/ 4 < count) throw _truncatedTable(box);
    return [for (var i = 0; i < count; i++) view.getUint32(12 + i * 4)];
  }

  /// Combines `stsc`, which says how many samples each chunk holds, with `stco` or `co64`, which
  /// say where each chunk starts, into a file offset per sample.
  ///
  /// `co64` is the 64-bit form any file over 4 GB needs. Reading it as `stco` would take the high
  /// half of each offset for the whole of it and misplace every chapter title.
  Future<List<int>> _sampleOffsets(_Box stbl, List<int> sizes) async {
    final stsc = await _content(await _table(stbl, 'stsc'));
    final narrow = await _findChild('stco', stbl.contentStart, stbl.end);
    final wide = narrow == null
        ? await _findChild('co64', stbl.contentStart, stbl.end)
        : null;
    final offsetsBox = narrow ?? wide;
    if (offsetsBox == null) {
      throw FormatException(
        'sample table at ${stbl.start} has no chunk offsets',
      );
    }
    final width = wide != null ? 8 : 4;

    final offsetsBody = await _content(offsetsBox);
    if (offsetsBody.length < 8) throw _truncatedTable(offsetsBox);
    final offsetsView = ByteData.sublistView(offsetsBody);
    final chunkCount = offsetsView.getUint32(4);
    if (chunkCount > _maxChapters) throw _tooMany(offsetsBox);
    if ((offsetsBody.length - 8) ~/ width < chunkCount) {
      throw _truncatedTable(offsetsBox);
    }
    final chunkOffsets = [
      for (var i = 0; i < chunkCount; i++)
        width == 8
            ? offsetsView.getUint64(8 + i * 8)
            : offsetsView.getUint32(8 + i * 4),
    ];

    if (stsc.length < 8)
      throw FormatException('stsc in ${stbl.start} is truncated');
    final stscView = ByteData.sublistView(stsc);
    final runCount = stscView.getUint32(4);
    if ((stsc.length - 8) ~/ 12 < runCount) {
      throw FormatException('stsc in ${stbl.start} is truncated');
    }
    final runs = [
      for (var i = 0; i < runCount; i++)
        (
          firstChunk: stscView.getUint32(8 + i * 12),
          samplesPerChunk: stscView.getUint32(12 + i * 12),
        ),
    ];
    if (runs.isEmpty) return const [];

    final offsets = <int>[];
    var sample = 0;
    for (var chunk = 0; chunk < chunkOffsets.length; chunk++) {
      // Chunks are numbered from one in stsc; the last run starting at or before this chunk applies.
      var perChunk = runs.first.samplesPerChunk;
      for (final run in runs) {
        if (run.firstChunk <= chunk + 1) perChunk = run.samplesPerChunk;
      }
      var offset = chunkOffsets[chunk];
      for (var k = 0; k < perChunk && sample < sizes.length; k++) {
        offsets.add(offset);
        offset += sizes[sample++];
      }
    }
    return offsets;
  }

  /// A text sample is a 16-bit length, that many bytes of title, then optional trailing atoms.
  Future<String> _textSample(int offset, int size) async {
    if (size < 2) return '';
    final header = await _bytes(offset, 2);
    final declared = ByteData.sublistView(header).getUint16(0);
    final length = math.min(declared, size - 2);
    if (length == 0) return '';
    return utf8.decode(await _bytes(offset + 2, length), allowMalformed: true);
  }
}
