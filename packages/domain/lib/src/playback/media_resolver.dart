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
/// A service interface, so it lives in the domain (§2.4). The data layer implements it for files on
/// the device, and the playback coordinator consumes it without knowing where files come from.
///
/// Implementations try, in order, a downloaded local file, a cached resolution that has not expired,
/// and a fresh call to the source.
abstract interface class MediaResolver {
  /// Resolves the file with id [fileId], throwing if it cannot.
  ///
  /// [refresh] bypasses any cached resolution. The coordinator sets it when retrying after a stream
  /// error, which is usually an expired URL.
  Future<ResolvedMedia> resolve(int fileId, {bool refresh = false});

  /// The resolution for [fileId] if it is already in hand, and null when getting it would mean
  /// asking a source.
  ///
  /// This is the first two steps of the order above without the third: a file on the device, or a
  /// resolution that has not expired. It exists so that opening a book can make playable everything
  /// that costs nothing — which for a local book is every file it has — and leave the rest to be
  /// resolved when the engine first asks for its bytes. Never throws: a file that cannot be
  /// resolved at all is simply not in hand, and says so when it is played.
  Future<ResolvedMedia?> resolveIfOnHand(int fileId);
}

/// Where a step's duration is reported, for finding out what a slow screen is waiting on.
///
/// The app passes one that writes to the console in a debug build and nothing at all in a release
/// one, so a measurement costs a shipped app nothing but the null check.
typedef TimingSink = void Function(String step, Duration took);
