/// The address a download was last told to fetch from (§5.2's request snapshot).
///
/// Kept because §5.4 forces just-in-time resolution: many sources hand out signed URLs that expire
/// within minutes, so the URL a task will actually use cannot be worked out when the listener queues
/// a book. It is resolved as the file is about to start, written down here with its expiry, and used
/// once. A 403, a 410 or a passed [DownloadTask]-level expiry sends the task back to the extension
/// rather than failing it.
///
/// This is the one place in the app where a URL is stored. §4.3 keeps them out of the library
/// deliberately — they are ephemeral, and the Timeline never needs one — and a download task is the
/// stated exception, because the transport has to be handed something after the app has been killed
/// and restarted.
library;

/// A URL and the headers a site wants with it.
final class DownloadRequest {
  const DownloadRequest({required this.url, this.headers = const {}});

  /// Where the bytes are. Absolute, and already held to the extension's declared domains by the
  /// contract's decoder before it ever reached here.
  final String url;

  /// What the site needs sent with the request: a referer, a token, a cookie (§6.3).
  final Map<String, String> headers;

  @override
  bool operator ==(Object other) =>
      other is DownloadRequest &&
      other.url == url &&
      _sameHeaders(other.headers, headers);

  @override
  int get hashCode => Object.hash(url, Object.hashAllUnordered(headers.keys));

  @override
  String toString() => headers.isEmpty
      ? 'DownloadRequest($url)'
      : 'DownloadRequest($url, ${headers.length} header(s))';

  static bool _sameHeaders(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
