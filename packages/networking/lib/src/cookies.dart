/// One cookie jar per extension (§3.5).
///
/// "Only manifest-declared domains; per-source rate limit; per-extension cookie jar;
/// host-controlled User-Agent; body size cap; timeout." The jar is per extension so that one
/// source's session cannot be read, or set, by another: cookies are how a site knows who is asking,
/// and an extension is not trusted with another's identity.
///
/// This is RFC 6265 as far as an audiobook scraper needs it: name, value, domain, path, expiry,
/// and `Secure`. It has no public-suffix list, so a cookie may only be set for the host that sent
/// it or for a parent domain of at least two labels — enough to stop `example.org` setting one for
/// `org`, and honest about not being a browser.
library;

import 'dart:io' show HttpDate;

/// One cookie, as a site set it.
final class Cookie {
  Cookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    this.expires,
    this.secure = false,
    this.hostOnly = true,
  });

  final String name;
  final String value;

  /// The host it belongs to, in lower case and without a leading dot.
  final String domain;

  /// The path prefix it is sent for.
  final String path;

  /// When it stops being sent. Null for a session cookie, which lives as long as the jar.
  final DateTime? expires;

  /// Only sent over https.
  final bool secure;

  /// Set without a `Domain`, so it is sent to that one host and not to its subdomains.
  final bool hostOnly;

  bool hasExpired(DateTime now) {
    final at = expires;
    return at != null && !at.isAfter(now);
  }

  @override
  String toString() => '$name=$value';
}

/// The cookies of one extension.
final class CookieJar {
  CookieJar({DateTime Function()? now, this.maxCookies = 200})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// How many cookies one extension may hold. A site uses a handful; this only bounds a server
  /// that would otherwise set them without end.
  final int maxCookies;

  final _cookies = <String, Cookie>{};

  /// Every cookie held, for a test or for showing what a source has stored.
  List<Cookie> get cookies => List.unmodifiable(_cookies.values);

  /// Takes the `Set-Cookie` headers of a response to [url].
  ///
  /// A cookie that names a domain the response has no business setting is dropped rather than
  /// failing the request: sites send them by accident, and the request itself was fine.
  void storeFromResponse(Uri url, Iterable<String> setCookieHeaders) {
    for (final header in setCookieHeaders) {
      final cookie = _parse(url, header);
      if (cookie == null) continue;
      final key = '${cookie.domain}\u0000${cookie.path}\u0000${cookie.name}';
      if (cookie.value.isEmpty && cookie.hasExpired(_now())) {
        _cookies.remove(key);
        continue;
      }
      _cookies[key] = cookie;
      if (_cookies.length > maxCookies) {
        // The oldest goes, which for a Map is the first inserted.
        _cookies.remove(_cookies.keys.first);
      }
    }
  }

  /// The `Cookie` header for a request to [url], or null when there is nothing to send.
  ///
  /// Longest path first, as RFC 6265 orders them, because that is what servers expect when two
  /// cookies share a name.
  String? headerFor(Uri url) {
    final now = _now();
    final host = _host(url.host);
    final path = url.path.isEmpty ? '/' : url.path;
    final matching = <Cookie>[];
    for (final entry in _cookies.entries.toList()) {
      final cookie = entry.value;
      if (cookie.hasExpired(now)) {
        _cookies.remove(entry.key);
        continue;
      }
      if (cookie.secure && url.scheme != 'https') continue;
      if (!_domainMatches(host, cookie)) continue;
      if (!_pathMatches(path, cookie.path)) continue;
      matching.add(cookie);
    }
    if (matching.isEmpty) return null;
    matching.sort((a, b) => b.path.length.compareTo(a.path.length));
    return matching
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  /// Forgets everything, as signing out of a source should.
  void clear() => _cookies.clear();

  static bool _domainMatches(String host, Cookie cookie) => cookie.hostOnly
      ? host == cookie.domain
      : host == cookie.domain || host.endsWith('.${cookie.domain}');

  static bool _pathMatches(String path, String cookiePath) {
    if (path == cookiePath) return true;
    if (!path.startsWith(cookiePath)) return false;
    return cookiePath.endsWith('/') || path[cookiePath.length] == '/';
  }

  static String _host(String host) {
    final lower = host.toLowerCase();
    return lower.endsWith('.') ? lower.substring(0, lower.length - 1) : lower;
  }

  /// The default path of a cookie set by a request to [path]: its directory (RFC 6265 §5.1.4).
  static String _defaultPath(String path) {
    if (path.isEmpty || !path.startsWith('/')) return '/';
    final lastSlash = path.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return path.substring(0, lastSlash);
  }

  Cookie? _parse(Uri url, String header) {
    final parts = header.split(';');
    final first = parts.first;
    final equals = first.indexOf('=');
    if (equals <= 0) return null;
    final name = first.substring(0, equals).trim();
    final value = first.substring(equals + 1).trim();
    if (name.isEmpty) return null;

    final host = _host(url.host);
    var domain = host;
    var hostOnly = true;
    var path = _defaultPath(url.path);
    DateTime? expires;
    int? maxAge;
    var secure = false;

    for (final attribute in parts.skip(1)) {
      final at = attribute.indexOf('=');
      final key = (at < 0 ? attribute : attribute.substring(0, at))
          .trim()
          .toLowerCase();
      final attributeValue = at < 0 ? '' : attribute.substring(at + 1).trim();
      switch (key) {
        case 'domain':
          final named = _host(
            attributeValue.startsWith('.')
                ? attributeValue.substring(1)
                : attributeValue,
          );
          // A site may set a cookie for itself or for a parent domain, never for anyone else and
          // never for a whole top-level domain.
          if (named.isEmpty ||
              !named.contains('.') ||
              !(host == named || host.endsWith('.$named'))) {
            return null;
          }
          domain = named;
          hostOnly = false;
        case 'path':
          if (attributeValue.startsWith('/')) path = attributeValue;
        case 'expires':
          try {
            expires = HttpDate.parse(attributeValue);
          } on Exception {
            // An unreadable date makes it a session cookie, which is what a browser does.
          }
        case 'max-age':
          maxAge = int.tryParse(attributeValue);
        case 'secure':
          secure = true;
      }
    }
    if (maxAge != null) {
      // Max-Age wins over Expires, and 0 or less means "gone now".
      expires = _now().add(Duration(seconds: maxAge));
    }
    return Cookie(
      name: name,
      value: value,
      domain: domain,
      path: path.isEmpty ? '/' : path,
      expires: expires,
      secure: secure,
      hostOnly: hostOnly,
    );
  }
}
