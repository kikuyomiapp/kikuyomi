/// Vorbis comments: the tags of FLAC, Ogg Vorbis and Ogg Opus files.
///
/// All three carry the same structure, a FLAC file in its VORBIS_COMMENT metadata block and the Ogg
/// codecs in the second packet of their stream: a vendor string, then a list of `NAME=value`
/// comments, each preceded by its length, little-endian. Names are ASCII and ignore case; values are
/// UTF-8. Two conventions ride on the comments and are read here too: `METADATA_BLOCK_PICTURE`, a
/// FLAC picture structure in base64, for cover art; and `CHAPTERnnn` with `CHAPTERnnnNAME`, which
/// ffmpeg and taggers write for chapter markers.
///
/// The comments are walked through a [ByteSource] rather than read whole. A comment holding a picture
/// can run to megabytes, and a folder scan, which asks for no cover, never needs them.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_reading.dart';
import 'embedded_chapter.dart';
import 'embedded_picture.dart';
import 'flac_picture.dart';
import 'mp4_chapters.dart' show ByteSource;

/// What a file's Vorbis comments say.
final class VorbisComment {
  const VorbisComment({
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

  /// `TITLE`: in a book's folder, usually the chapter's title.
  final String? title;

  /// `ARTIST`, conventionally the author.
  final String? artist;

  /// `ALBUMARTIST`, or as some taggers write it `ALBUM ARTIST` or `ALBUM_ARTIST`.
  final String? albumArtist;

  /// `ALBUM`: in a book's folder, usually the book's title.
  final String? album;

  /// `COMPOSER`, which audiobook taggers commonly use for the narrator, as they do in MP3 and MP4.
  final String? composer;

  /// `TRACKNUMBER`, without any "of" count.
  final int? trackNumber;

  /// `DISCNUMBER`, without any "of" count.
  final int? discNumber;

  /// From the `CHAPTERnnn` comments, in order of their start.
  final List<EmbeddedChapter> chapters;

  /// From a `METADATA_BLOCK_PICTURE` comment. Always null unless a cover was asked for.
  final EmbeddedPicture? cover;
}

/// Reads the Vorbis comments in [source] from [start] to [end], and the cover among them if
/// [withCover] is true.
///
/// Throws a [FormatException] when a length runs past [end], or the comments claim more entries than
/// any real file has: the structure is damaged, and nothing after the fault can be found. A value
/// that is merely unusable, such as a chapter time that does not parse or a picture that does not
/// decode, is skipped instead.
///
/// When a name is given more than once, its first value is kept. The cover is the picture the
/// comments mark as the front cover, or failing that their first picture.
///
/// Each `CHAPTERnnn` comment gives a chapter's start as `hh:mm:ss.sss`, and `CHAPTERnnnNAME` its
/// title. The numbers only pair the two: ffmpeg counts from 000 and the convention's own description
/// from 001, so chapters are put in order by their start. One with no name is called "Chapter" and
/// its place in that order, counting from one, and one whose start does not parse is left out.
Future<VorbisComment> readVorbisComment(
  ByteSource source, {
  required int start,
  required int end,
  bool withCover = false,
}) async {
  final reader = _Reader(source, end);
  var p = start;
  Future<int> u32() async {
    final bytes = await reader.read(p, 4);
    p += 4;
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  final vendorLength = await u32();
  if (vendorLength > end - p) {
    throw FormatException(
      'Vorbis comments at $start have a vendor string of $vendorLength bytes, '
      'more than the ${end - p} left',
    );
  }
  p += vendorLength;
  final count = await u32();
  // Every comment takes at least the four bytes of its length, which bounds how many fit.
  if (count > (end - p) ~/ 4 || count > _maxComments) {
    throw FormatException(
      'Vorbis comments at $start claim $count comments, more than their '
      '${end - p} bytes can hold',
    );
  }

  final tags = <String, String>{};
  final starts = <int, int>{};
  final names = <int, String>{};
  _PictureComment? firstPicture;
  _PictureComment? frontCover;
  for (var i = 0; i < count; i++) {
    final length = await u32();
    if (length > end - p) {
      throw FormatException(
        'Vorbis comment $i at $p is $length bytes long, more than the '
        '${end - p} left',
      );
    }
    final head = await reader.read(p, math.min(length, _nameBytes));
    final equals = head.indexOf(0x3D); // =
    if (equals > 0) {
      final name = String.fromCharCodes(head, 0, equals).toUpperCase();
      final valueAt = p + equals + 1;
      final valueLength = length - equals - 1;
      if (name == 'METADATA_BLOCK_PICTURE') {
        if (withCover && frontCover == null && valueLength <= _maxPictureText) {
          final picture = await _PictureComment.probe(
            reader,
            valueAt,
            valueLength,
          );
          if (picture != null) {
            firstPicture ??= picture;
            if (picture.type == frontCoverType) frontCover = picture;
          }
        }
      } else if (valueLength <= _maxTextBytes) {
        final chapter = _chapterName.firstMatch(name);
        final tag = _tagNames[name];
        if (chapter != null || tag != null) {
          final value = utf8
              .decode(
                await reader.read(valueAt, valueLength),
                allowMalformed: true,
              )
              .trim();
          if (chapter != null) {
            final number = int.parse(chapter[1]!);
            if (chapter[2] == null) {
              final startMs = _chapterStart(value);
              if (startMs != null) starts.putIfAbsent(number, () => startMs);
            } else if (value.isNotEmpty) {
              names.putIfAbsent(number, () => value);
            }
          } else if (value.isNotEmpty) {
            tags.putIfAbsent(tag!, () => value);
          }
        }
      }
    }
    p += length;
  }

  final ordered = starts.entries.toList()
    // By start, and by number between chapters that start together, so the order never depends on
    // how the sort treats ties.
    ..sort(
      (a, b) => switch (a.value.compareTo(b.value)) {
        0 => a.key.compareTo(b.key),
        final byStart => byStart,
      },
    );
  final picture = frontCover ?? firstPicture;
  return VorbisComment(
    title: tags['title'],
    artist: tags['artist'],
    albumArtist: tags['albumArtist'],
    album: tags['album'],
    composer: tags['composer'],
    trackNumber: leadingNumber(tags['track']),
    discNumber: leadingNumber(tags['disc']),
    chapters: [
      for (final (i, MapEntry(key: number, value: startMs)) in ordered.indexed)
        EmbeddedChapter(
          startMs: startMs,
          title: names[number] ?? 'Chapter ${i + 1}',
        ),
    ],
    cover: picture == null ? null : await picture.read(reader),
  );
}

/// The comments read as tags, by name, and what each is kept as.
const _tagNames = {
  'TITLE': 'title',
  'ARTIST': 'artist',
  'ALBUMARTIST': 'albumArtist',
  'ALBUM ARTIST': 'albumArtist',
  'ALBUM_ARTIST': 'albumArtist',
  'ALBUM': 'album',
  'COMPOSER': 'composer',
  'TRACKNUMBER': 'track',
  'DISCNUMBER': 'disc',
};

/// `CHAPTER001` for a chapter's start, `CHAPTER001NAME` for its title. Up to five digits, which is
/// more chapters than any book has and few enough that the number always parses.
final _chapterName = RegExp(r'^CHAPTER(\d{1,5})(NAME)?$');

/// A chapter's start, as `hh:mm:ss` with an optional fraction of a second.
final _chapterTime = RegExp(r'^(\d{1,4}):([0-5]?\d):([0-5]?\d)(?:\.(\d+))?$');

/// [value], a chapter's start, in milliseconds, or null when it is not a time.
int? _chapterStart(String value) {
  final match = _chapterTime.firstMatch(value);
  if (match == null) return null;
  final hours = int.parse(match[1]!);
  final minutes = int.parse(match[2]!);
  final seconds = int.parse(match[3]!);
  // Milliseconds are the fraction's first three digits, however many it has.
  final fraction = (match[4] ?? '').padRight(3, '0').substring(0, 3);
  return ((hours * 60 + minutes) * 60 + seconds) * 1000 + int.parse(fraction);
}

/// Comments larger than this are skipped, unless they hold a picture. Titles and names are tiny; the
/// bound stops a damaged file claiming a huge one.
const _maxTextBytes = 64 * 1024;

/// How much of a comment is read to find its name. Every name read here is shorter.
const _nameBytes = 64;

/// No real file has this many comments, even with a comment pair for each of thousands of chapters.
/// The bound stops a damaged file from keeping the reader busy with millions of empty ones.
const _maxComments = 65536;

/// The largest `METADATA_BLOCK_PICTURE` value read: a picture of [maxPictureBytes] with generous
/// room for its MIME type and description, in base64, which takes four characters for three bytes.
const _maxPictureText = (maxPictureBytes + 64 * 1024) * 4 ~/ 3 + 4;

/// Where a `METADATA_BLOCK_PICTURE` value is, and the picture type it states.
final class _PictureComment {
  const _PictureComment(this.offset, this.length, this.type);

  /// Reads just enough of the value at [offset] to learn its picture type: the first eight base64
  /// characters, which are six bytes. Null when the value is too short or not base64.
  static Future<_PictureComment?> probe(
    _Reader reader,
    int offset,
    int length,
  ) async {
    if (length < 8) return null;
    try {
      final head = base64.decode(
        String.fromCharCodes(await reader.read(offset, 8)),
      );
      final type = flacPictureType(head);
      return type == null ? null : _PictureComment(offset, length, type);
    } on FormatException {
      return null;
    }
  }

  final int offset;
  final int length;
  final int type;

  /// Decodes the picture. Null when it is not base64, or holds no image [parseFlacPicture] can use.
  Future<EmbeddedPicture?> read(_Reader reader) async {
    final text = String.fromCharCodes(await reader.read(offset, length));
    try {
      return parseFlacPicture(base64.decode(base64.normalize(text.trim())));
    } on FormatException {
      return null;
    }
  }
}

/// Reads runs of bytes up to [_end], a chunk at a time, so that walking many small comments costs a
/// few reads of the source rather than two for every comment. A run larger than a chunk, as a
/// picture is, is read on its own.
final class _Reader {
  _Reader(this._source, this._end);

  final ByteSource _source;
  final int _end;

  static const _chunkBytes = 64 * 1024;

  int _chunkStart = 0;
  Uint8List _chunk = Uint8List(0);

  Future<Uint8List> read(int offset, int count) async {
    if (count > _end - offset) {
      throw FormatException(
        'Vorbis comments end at $_end, before the $count bytes at $offset',
      );
    }
    final at = offset - _chunkStart;
    if (at >= 0 && count <= _chunk.length - at) {
      return Uint8List.sublistView(_chunk, at, at + count);
    }
    if (count > _chunkBytes) {
      return readExactly(_source, offset, count, what: 'a Vorbis comment');
    }
    _chunk = await readExactly(
      _source,
      offset,
      math.min(_chunkBytes, _end - offset),
      what: 'the Vorbis comments',
    );
    _chunkStart = offset;
    return Uint8List.sublistView(_chunk, 0, count);
  }
}
