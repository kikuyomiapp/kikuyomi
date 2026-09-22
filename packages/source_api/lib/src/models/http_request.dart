/// SourceAPI 1.0's `HttpRequest`: how to fetch something from a source's site.
library;

import '../equality.dart';

/// The request methods an extension may use.
enum HttpMethod {
  get('GET'),
  post('POST');

  const HttpMethod(this.wireName);

  /// The method as HTTP and the contract write it.
  final String wireName;
}

/// A request for a page, an image or audio, with whatever headers the site needs (§6.3).
///
/// This package's decoders only produce requests whose URL passed the domain check and whose
/// headers passed the header rules, so a request that reaches the network layer from an extension
/// is always one the extension was allowed to make.
///
/// Named as the contract names it. Code that also imports `dart:io`, which has an `HttpRequest` of
/// its own, hides one of the two or imports with a prefix.
final class HttpRequest {
  HttpRequest({
    required this.url,
    this.method = HttpMethod.get,
    Map<String, String> headers = const {},
    this.body,
  }) : headers = Map.unmodifiable(headers);

  /// An absolute `http` or `https` URL.
  final Uri url;
  final HttpMethod method;

  /// Header names as the extension wrote them. No two differ only in case.
  final Map<String, String> headers;

  /// The body of a POST request. A GET request has none.
  final String? body;

  @override
  bool operator ==(Object other) =>
      other is HttpRequest &&
      other.url == url &&
      other.method == method &&
      mapEquals(other.headers, headers) &&
      other.body == body;

  @override
  int get hashCode => Object.hash(url, method, mapHash(headers), body);

  @override
  String toString() => 'HttpRequest(${method.wireName} $url)';
}
