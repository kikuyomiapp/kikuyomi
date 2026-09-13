// Spike (d), second half: the QuickTime chapter track. Throwaway.
//
// The first half read chapters from the Nero `chpl` atom. That covers files written by ffmpeg and
// most taggers, but Apple's own tools write chapters ONLY as a QuickTime chapter track, and a
// reader that does not understand it reports "no chapters" for that whole lineage of files and
// treats a twenty-hour book as one undivided item.
//
// A chapter track is an ordinary MP4 track of timed text:
//
//   audio trak --tref/chap--> chapter trak (handler 'text')
//                               mdia/mdhd            -> timescale
//                               mdia/minf/stbl/stts  -> per-sample durations, cumulative = starts
//                               mdia/minf/stbl/stsz  -> per-sample byte sizes
//                               mdia/minf/stbl/stsc  -> how samples group into chunks
//                               mdia/minf/stbl/stco  -> file offset of each chunk
//   each sample: uint16 length, then `length` bytes of UTF-8 title, then optional trailing atoms
//
// Everything here is seek-based for the same reason as the first half: real books reach a
// gigabyte and must never be loaded into memory.
//
// Run: dart run bin/qt_chapters.dart fixtures/sample.m4b

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Chapter {
  final Duration start;
  final String title;
  const Chapter(this.start, this.title);

  @override
  String toString() {
    final d = start;
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s.$ms  $title';
  }
}

class _Box {
  final String type;
  final int start; // offset of the box header
  final int size;
  const _Box(this.type, this.start, this.size);
  int get contentStart => start + 8;
  int get end => start + size;
}

/// Seek-based MP4 reader. Reads box headers and small payloads only.
class QtChapterReader {
  final RandomAccessFile _f;
  final int _length;
  int bytesRead = 0;

  QtChapterReader(this._f) : _length = _f.lengthSync();

  Uint8List _read(int off, int n) {
    _f.setPositionSync(off);
    bytesRead += n;
    return _f.readSync(n);
  }

  int _u32(Uint8List b, int o) => ByteData.sublistView(b).getUint32(o);

  /// Lists the direct children of the region [from, to).
  List<_Box> _children(int from, int to) {
    final out = <_Box>[];
    var off = from;
    while (off + 8 <= to) {
      final head = _read(off, 8);
      final size = _u32(head, 0);
      final type = String.fromCharCodes(head, 4, 8);
      final boxSize = size == 0 ? to - off : size;
      if (boxSize < 8 || off + boxSize > to) break;
      out.add(_Box(type, off, boxSize));
      off += boxSize;
    }
    return out;
  }

  /// Follows a path of box types down from [from, to). Returns null if any step is missing.
  _Box? _path(List<String> path, int from, int to) {
    var lo = from, hi = to;
    _Box? found;
    for (final want in path) {
      found = null;
      for (final b in _children(lo, hi)) {
        if (b.type == want) {
          found = b;
          break;
        }
      }
      if (found == null) return null;
      lo = found.contentStart;
      hi = found.end;
    }
    return found;
  }

  /// Reads the track_id out of a `tkhd`, which differs by version.
  int _trackId(_Box tkhd) {
    final head = _read(tkhd.contentStart, 4);
    final version = head[0];
    // version 0: creation(4) modification(4) track_id(4)
    // version 1: creation(8) modification(8) track_id(4)
    final idOff = tkhd.contentStart + 4 + (version == 0 ? 8 : 16);
    return _u32(_read(idOff, 4), 0);
  }

  /// Returns the chapter track's samples as chapters, or null if the file has no chapter track.
  List<Chapter>? read() {
    final moov = _path(['moov'], 0, _length);
    if (moov == null) return null;
    final traks = _children(
      moov.contentStart,
      moov.end,
    ).where((b) => b.type == 'trak').toList();
    if (traks.isEmpty) return null;

    // Which track does the audio track point at?
    int? chapterTrackId;
    for (final t in traks) {
      final chap = _path(['tref', 'chap'], t.contentStart, t.end);
      if (chap != null) {
        chapterTrackId = _u32(_read(chap.contentStart, 4), 0);
        break;
      }
    }
    if (chapterTrackId == null) return null;

    // Find that track.
    _Box? chapterTrak;
    for (final t in traks) {
      final tkhd = _path(['tkhd'], t.contentStart, t.end);
      if (tkhd != null && _trackId(tkhd) == chapterTrackId) {
        chapterTrak = t;
        break;
      }
    }
    // Some writers leave track ids at zero. Fall back to the first text-handler track.
    chapterTrak ??= traks.firstWhere((t) {
      final hdlr = _path(['mdia', 'hdlr'], t.contentStart, t.end);
      if (hdlr == null) return false;
      final h = _read(hdlr.contentStart + 8, 4);
      return String.fromCharCodes(h) == 'text';
    }, orElse: () => traks.last);

    final lo = chapterTrak.contentStart, hi = chapterTrak.end;

    final mdhd = _path(['mdia', 'mdhd'], lo, hi);
    if (mdhd == null) return null;
    final mdhdVersion = _read(mdhd.contentStart, 4)[0];
    // version 0: creation(4) modification(4) timescale(4)
    // version 1: creation(8) modification(8) timescale(4)
    final tsOff = mdhd.contentStart + 4 + (mdhdVersion == 0 ? 8 : 16);
    final timescale = _u32(_read(tsOff, 4), 0);
    if (timescale == 0) return null;

    final durations = _readStts(lo, hi);
    final sizes = _readStsz(lo, hi);
    final offsets = _sampleOffsets(lo, hi);
    if (durations.isEmpty || sizes.isEmpty || offsets.isEmpty) return null;

    final count = [
      durations.length,
      sizes.length,
      offsets.length,
    ].reduce((a, b) => a < b ? a : b);
    final out = <Chapter>[];
    var elapsed = 0;
    for (var i = 0; i < count; i++) {
      final title = _readTextSample(offsets[i], sizes[i]);
      final startMs = (elapsed * 1000) ~/ timescale;
      out.add(Chapter(Duration(milliseconds: startMs), title));
      elapsed += durations[i];
    }
    return out;
  }

  /// `stts` is run-length encoded: (sampleCount, sampleDelta) pairs.
  List<int> _readStts(int lo, int hi) {
    final b = _path(['mdia', 'minf', 'stbl', 'stts'], lo, hi);
    if (b == null) return const [];
    final body = _read(b.contentStart, b.size - 8);
    final entries = _u32(body, 4);
    final out = <int>[];
    for (var i = 0; i < entries; i++) {
      final o = 8 + i * 8;
      if (o + 8 > body.length) break;
      final n = _u32(body, o);
      final delta = _u32(body, o + 4);
      for (var k = 0; k < n; k++) {
        out.add(delta);
      }
    }
    return out;
  }

  /// `stsz` either gives one size for every sample, or a size per sample.
  List<int> _readStsz(int lo, int hi) {
    final b = _path(['mdia', 'minf', 'stbl', 'stsz'], lo, hi);
    if (b == null) return const [];
    final body = _read(b.contentStart, b.size - 8);
    final uniform = _u32(body, 4);
    final count = _u32(body, 8);
    if (uniform != 0) return List.filled(count, uniform);
    final out = <int>[];
    for (var i = 0; i < count; i++) {
      final o = 12 + i * 4;
      if (o + 4 > body.length) break;
      out.add(_u32(body, o));
    }
    return out;
  }

  /// Combines `stsc` (samples per chunk) and `stco` (chunk offsets) into a file offset per sample.
  List<int> _sampleOffsets(int lo, int hi) {
    final stsc = _path(['mdia', 'minf', 'stbl', 'stsc'], lo, hi);
    final stco = _path(['mdia', 'minf', 'stbl', 'stco'], lo, hi);
    if (stsc == null || stco == null) return const [];

    final chunkBody = _read(stco.contentStart, stco.size - 8);
    final chunkCount = _u32(chunkBody, 4);
    final chunkOffsets = <int>[];
    for (var i = 0; i < chunkCount; i++) {
      final o = 8 + i * 4;
      if (o + 4 > chunkBody.length) break;
      chunkOffsets.add(_u32(chunkBody, o));
    }

    final scBody = _read(stsc.contentStart, stsc.size - 8);
    final scEntries = _u32(scBody, 4);
    final runs = <(int firstChunk, int perChunk)>[];
    for (var i = 0; i < scEntries; i++) {
      final o = 8 + i * 12;
      if (o + 12 > scBody.length) break;
      runs.add((_u32(scBody, o), _u32(scBody, o + 4)));
    }
    if (runs.isEmpty) return const [];

    final sizes = _readStsz(lo, hi);
    final out = <int>[];
    var sampleIndex = 0;
    for (var c = 0; c < chunkOffsets.length; c++) {
      // How many samples live in chunk c? The last run whose firstChunk <= c+1 wins.
      var perChunk = runs.first.$2;
      for (final r in runs) {
        if (r.$1 <= c + 1) perChunk = r.$2;
      }
      var off = chunkOffsets[c];
      for (var k = 0; k < perChunk && sampleIndex < sizes.length; k++) {
        out.add(off);
        off += sizes[sampleIndex];
        sampleIndex++;
      }
    }
    return out;
  }

  /// A text sample is a uint16 length followed by that many UTF-8 bytes. Anything after it is a
  /// trailing atom such as `encd` and is ignored.
  String _readTextSample(int offset, int size) {
    if (size < 2) return '';
    final b = _read(offset, size);
    final len = ByteData.sublistView(b).getUint16(0);
    final endIdx = (2 + len) <= b.length ? 2 + len : b.length;
    return utf8.decode(b.sublist(2, endIdx), allowMalformed: true);
  }
}

void main(List<String> args) {
  final path = args.isNotEmpty ? args.first : 'fixtures/sample.m4b';
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('missing fixture: $path (run fixtures/make.sh first)');
    exit(2);
  }

  final raf = file.openSync();
  final sw = Stopwatch()..start();
  final reader = QtChapterReader(raf);
  final chapters = reader.read();
  sw.stop();
  raf.closeSync();

  stdout.writeln('--- spike (d) second half: QuickTime chapter track ---');
  stdout.writeln('file: $path (${file.lengthSync()} bytes)');
  stdout.writeln(
    'parsed in ${sw.elapsedMicroseconds}us, '
    'read ${reader.bytesRead} bytes '
    '(${(reader.bytesRead * 100 / file.lengthSync()).toStringAsFixed(2)}%)',
  );
  stdout.writeln('');

  if (chapters == null) {
    stdout.writeln('no QuickTime chapter track found');
    exit(1);
  }

  stdout.writeln('chapters: ${chapters.length}');
  for (final c in chapters) {
    stdout.writeln('  $c');
  }

  const expected = [
    (0, 'Chapter One'),
    (4000, 'Chapter Two'),
    (9000, 'Chapter Three'),
  ];
  var failures = 0;
  if (chapters.length != expected.length) {
    stdout.writeln('FAIL: expected ${expected.length}, got ${chapters.length}');
    failures++;
  } else {
    for (var i = 0; i < expected.length; i++) {
      final (ms, title) = expected[i];
      if (chapters[i].start.inMilliseconds != ms ||
          chapters[i].title != title) {
        stdout.writeln(
          'FAIL: chapter $i expected ${ms}ms "$title", got '
          '${chapters[i].start.inMilliseconds}ms "${chapters[i].title}"',
        );
        failures++;
      }
    }
  }

  stdout.writeln('');
  stdout.writeln(
    failures == 0
        ? '--- matches the chpl reader exactly; both formats agree ---'
        : '--- $failures mismatches ---',
  );
  exit(failures == 0 ? 0 : 1);
}
