/// The domains an extension may name: SourceAPI 1.0's URL rule.
///
/// "Any URL: `http` or `https`, and a host the manifest's `domains` allow, wildcards included." The
/// rule covers every URL an extension fetches or hands the app: pages it fetches, a book's cover,
/// its web page, every segment and variant, a cover's request, and the page a challenge points at
/// (ADR-0016). The domains on the permissions screen before install are then every domain the
/// source can make the app contact.
///
/// A URL is checked as `Uri` parses it, and it is that parsed URL the app uses, never the text the
/// extension wrote. Two parsers can read one string differently — `https://ex%61mple.org/` and
/// `https://example.org/` are the same host to one and different to another — and handing on the
/// parsed form is what keeps the host that was checked the host that is contacted.
library;

/// The hosts an extension may reach: its manifest's `domains`, as exact hosts and `*.` wildcards.
///
/// - Hosts are compared in lower case, and a trailing dot is ignored: `Example.ORG.` is
///   `example.org`.
/// - `*.example.org` matches a subdomain at any depth, `a.example.org` and `a.b.example.org`
///   alike, but never `example.org` itself. To allow both, list both, as the manifest in §3.3 does.
/// - Any port is allowed on an allowed host: a port is not a domain.
/// - IP addresses and `localhost` are never allowed, in an entry or in a URL. An extension names
///   domains, so that the permissions screen can show what it will contact, and so that it cannot
///   reach a device on the listener's own network.
/// - Internationalised names are written in their `xn--` (A-label) form, in the manifest and in
///   URLs alike. The app has no IDNA implementation to convert one to the other, and guessing
///   would be a way past the allowlist.
final class DomainAllowlist {
  /// Builds the allowlist from a manifest's `domains`.
  ///
  /// Throws [FormatException] naming the first entry that is not a domain. Entries are normalised
  /// to lower case without a trailing dot, and repeats are dropped.
  factory DomainAllowlist(Iterable<String> domains) {
    final entries = <String>[];
    final exact = <String>{};
    final wildcards = <String>{};
    for (final domain in domains) {
      final entry = _normalise(domain);
      final wildcard = entry.startsWith('*.');
      final host = wildcard ? entry.substring(2) : entry;
      final problem = host.contains('*')
          ? 'a wildcard covers the subdomains of a domain, as in "*.example.org"'
          : _hostProblem(host) ?? _domainProblem(host);
      if (problem != null) {
        throw FormatException('domain "$domain": $problem');
      }
      if (entries.contains(entry)) continue;
      entries.add(entry);
      (wildcard ? wildcards : exact).add(host);
    }
    return DomainAllowlist._(List.unmodifiable(entries), exact, wildcards);
  }

  const DomainAllowlist._(this.domains, this._exact, this._wildcards);

  /// An allowlist that allows nothing, for a source that fetches nothing.
  static const none = DomainAllowlist._([], {}, {});

  /// The entries as the permissions screen shows them, in the manifest's order.
  final List<String> domains;

  final Set<String> _exact;
  final Set<String> _wildcards;

  /// Whether [host] is one of the domains, or a subdomain of a wildcard entry.
  bool allowsHost(String host) {
    final name = _normalise(host);
    if (_exact.contains(name)) return true;
    for (final base in _wildcards) {
      if (name.length > base.length + 1 && name.endsWith('.$base')) return true;
    }
    return false;
  }

  /// Whether the extension may fetch [url], or hand it to the app.
  bool allows(Uri url) => problemWith(url) == null;

  /// Why the extension may not fetch [url], or null when it may.
  ///
  /// The reason is a phrase that reads after the name of the field the URL came from, such as
  /// `coverUrl: the host "cdn.example.net" is not among the extension's domains`.
  String? problemWith(Uri url) {
    if (url.scheme.isEmpty) {
      return 'is not an absolute URL; resolve it against the page first';
    }
    if (url.scheme != 'http' && url.scheme != 'https') {
      return 'only http and https URLs are allowed, not "${url.scheme}"';
    }
    if (url.userInfo.isNotEmpty) {
      return 'must not carry a user name or password';
    }
    final host = _normalise(url.host);
    final problem = _hostProblem(host);
    if (problem != null) return problem;
    if (url.hasPort && (url.port < 1 || url.port > 65535)) {
      return '${url.port} is not a port';
    }
    if (!allowsHost(host)) {
      return 'the host "$host" is not among the extension\'s domains';
    }
    return null;
  }

  /// Reads [text] as a URL the extension may use.
  ///
  /// Throws [FormatException] whose message says why it may not, in the same words as
  /// [problemWith].
  Uri checkUrl(String text) {
    final problem = _textProblem(text);
    if (problem != null) throw FormatException(problem);
    final Uri url;
    try {
      url = Uri.parse(text);
    } on FormatException catch (error) {
      throw FormatException('is not a URL: ${error.message}');
    }
    final rejected = problemWith(url);
    if (rejected != null) throw FormatException(rejected);
    return url;
  }

  @override
  String toString() => 'DomainAllowlist(${domains.join(', ')})';
}

/// Lower case, without a trailing dot: a host name in the one form everything here compares.
String _normalise(String host) {
  final lower = host.toLowerCase();
  return lower.endsWith('.') ? lower.substring(0, lower.length - 1) : lower;
}

/// Why a URL's text cannot be read as one at all, before it is parsed.
///
/// Whitespace and control characters are where parsers disagree most: one strips them, one
/// percent-encodes them, one splits the URL at them. A backslash is read as a slash by browsers and
/// as itself elsewhere. None of them belong in a URL an extension built, so they are refused rather
/// than normalised.
String? _textProblem(String text) {
  if (text.isEmpty) return 'is empty';
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x20 || unit == 0x7f) {
      return 'contains a control character (U+${unit.toRadixString(16).toUpperCase().padLeft(4, '0')})';
    }
    if (unit == 0x5c) return 'contains a backslash';
  }
  if (text.startsWith(' ') || text.endsWith(' ')) {
    return 'begins or ends with a space';
  }
  return null;
}

/// Why [host], already normalised, is not a host an extension may name.
String? _hostProblem(String host) {
  if (host.isEmpty) return 'has no host';
  if (host.length > 253) return 'the host is longer than 253 characters';
  if (host.contains(':')) {
    return 'the host "$host" is an IP address; extensions name domains';
  }
  for (var i = 0; i < host.length; i++) {
    final unit = host.codeUnitAt(i);
    final letter = unit >= 0x61 && unit <= 0x7a;
    final digit = unit >= 0x30 && unit <= 0x39;
    if (!letter && !digit && unit != 0x2d && unit != 0x2e) {
      return 'the host "$host" is not a domain name: it holds only letters, digits, hyphens and '
          'dots, and an internationalised name is written in its xn-- form';
    }
  }
  final labels = host.split('.');
  for (final label in labels) {
    if (label.isEmpty || label.length > 63) {
      return 'the host "$host" is not a domain name: a label is empty or longer than 63 characters';
    }
    if (label.startsWith('-') || label.endsWith('-')) {
      return 'the host "$host" is not a domain name: a label begins or ends with a hyphen';
    }
  }
  final last = labels.last;
  final startsWithLetter =
      last.codeUnitAt(0) >= 0x61 && last.codeUnitAt(0) <= 0x7a;
  if (!startsWithLetter) {
    return 'the host "$host" is an IP address; extensions name domains';
  }
  if (host == 'localhost' || host.endsWith('.localhost')) {
    return 'the host "$host" is the device itself, which an extension may not reach';
  }
  return null;
}

/// Why [host] cannot be an entry of `domains`, beyond what [_hostProblem] rules out.
String? _domainProblem(String host) => host.contains('.')
    ? null
    : 'a domain needs at least two labels, so that a whole top-level domain cannot be allowed at '
          'once';
