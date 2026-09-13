import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// Where one physical file's audio can be fetched from.
final class ResolvedMedia {
  const ResolvedMedia({
    required this.uri,
    this.headers = const {},
    this.expiresAt,
  });

  /// A `file:` URI for a local or downloaded file, or a network URI for a stream.
  final Uri uri;

  /// §6.3: many sources need a referer, a token or cookies on every request.
  final Map<String, String> headers;

  /// When a stream URL stops working, if the source said. Many do expire.
  final DateTime? expiresAt;
}

/// §6.3's resolver: turns a physical file into something the engine can open.
///
/// Implementations try, in order, a downloaded local file, a cached resolution that has not
/// expired, and a fresh call to the source.
abstract interface class MediaResolver {
  /// Resolves the file with id [fileId], throwing if it cannot.
  ///
  /// [refresh] bypasses any cached resolution. The coordinator sets it when retrying after a stream
  /// error, which is usually an expired URL.
  Future<ResolvedMedia> resolve(int fileId, {bool refresh = false});
}

/// A queue item made playable: the Timeline's stretch of a file, and where to fetch that file from.
final class EngineItem {
  const EngineItem({required this.item, required this.media});

  final QueueItem item;
  final ResolvedMedia media;
}
