/// A chapter's audio: SourceAPI 1.0's `ResolveContext`, `MediaResolution` and `MediaSegment`.
///
/// One contract covers every audiobook layout (§3.4). An M4B with thirty chapters is thirty chapters
/// that each resolve to the same file, by [MediaSegment.fileKey], with different ranges. A chapter
/// split over three files resolves to three segments. Engine queue items are files, not chapters
/// (§6.2), so the file key is what the app downloads and plays by.
library;

import '../equality.dart';
import 'http_request.dart';

/// What a chapter is being resolved for.
enum ResolvePurpose { stream, download }

/// The kind of network the device is on, so that a source can pick a smaller variant on cellular.
enum NetworkType { wifi, cellular, unknown }

/// What the app tells a source when it asks for a chapter's audio.
final class ResolveContext {
  const ResolveContext({required this.purpose, required this.network});

  final ResolvePurpose purpose;
  final NetworkType network;

  @override
  bool operator ==(Object other) =>
      other is ResolveContext &&
      other.purpose == purpose &&
      other.network == network;

  @override
  int get hashCode => Object.hash(purpose, network);

  @override
  String toString() => 'ResolveContext(${purpose.name}, ${network.name})';
}

/// How a file's audio is packed, as the source says.
///
/// Named apart from the domain's `AudioFormat`, which is what the app has found a file to be and
/// is packed differently (MP4 rather than M4A and M4B, Ogg split by codec). The source's word is a
/// hint; the app probes a file before trusting it (§4.5).
enum MediaFormat { mp3, m4a, m4b, aac, flac, ogg, opus, hls, unknown }

/// A chapter's audio, as `resolveMedia` gives it.
final class MediaResolution {
  MediaResolution({required List<MediaSegment> segments, this.expiresAt})
    : segments = List.unmodifiable(segments);

  /// Played in order, they form the chapter. At least one.
  final List<MediaSegment> segments;

  /// When the URLs stop working, if the source says. The app resolves the chapter again after it.
  final DateTime? expiresAt;

  @override
  bool operator ==(Object other) =>
      other is MediaResolution &&
      listEquals(other.segments, segments) &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(Object.hashAll(segments), expiresAt);

  @override
  String toString() => 'MediaResolution(${segments.length} segments)';
}

/// The part of a physical file that belongs to a chapter.
final class MediaRange {
  const MediaRange({required this.startMs, this.endMs});

  /// Where the chapter starts in the file, in milliseconds.
  final int startMs;

  /// Where it ends, exclusive, or null for the end of the file. Always after [startMs].
  final int? endMs;

  @override
  bool operator ==(Object other) =>
      other is MediaRange && other.startMs == startMs && other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() => 'MediaRange($startMs-${endMs ?? 'end'})';
}

/// Another quality of the same file.
final class MediaVariant {
  const MediaVariant({
    required this.label,
    required this.request,
    this.bitrateKbps,
  });

  /// What to call the variant when offering a choice, such as "64 kbps".
  final String label;
  final int? bitrateKbps;
  final HttpRequest request;

  @override
  bool operator ==(Object other) =>
      other is MediaVariant &&
      other.label == label &&
      other.bitrateKbps == bitrateKbps &&
      other.request == request;

  @override
  int get hashCode => Object.hash(label, bitrateKbps, request);

  @override
  String toString() => 'MediaVariant("$label")';
}

/// One stretch of one physical file.
final class MediaSegment {
  MediaSegment({
    required this.fileKey,
    required this.request,
    this.format = MediaFormat.unknown,
    this.range,
    this.durationMs,
    this.sizeBytes,
    List<MediaVariant> variants = const [],
  }) : variants = List.unmodifiable(variants);

  /// The physical file's stable id within the book. Chapters that share a file share its key.
  final String fileKey;

  /// How to fetch the file. The default quality when there are [variants].
  final HttpRequest request;

  /// [MediaFormat.unknown] when the source does not say, or says something this app does not know.
  final MediaFormat format;

  /// The part of the file that belongs to the chapter. Null means the whole file.
  final MediaRange? range;

  /// The whole file's length, in milliseconds, when known. Not the range's.
  final int? durationMs;

  /// The whole file's size, in bytes, when known.
  final int? sizeBytes;

  /// Other qualities of the same file, besides [request].
  final List<MediaVariant> variants;

  @override
  bool operator ==(Object other) =>
      other is MediaSegment &&
      other.fileKey == fileKey &&
      other.request == request &&
      other.format == format &&
      other.range == range &&
      other.durationMs == durationMs &&
      other.sizeBytes == sizeBytes &&
      listEquals(other.variants, variants);

  @override
  int get hashCode => Object.hash(
    fileKey,
    request,
    format,
    range,
    durationMs,
    sizeBytes,
    Object.hashAll(variants),
  );

  @override
  String toString() => 'MediaSegment($fileKey, ${range ?? 'whole file'})';
}
