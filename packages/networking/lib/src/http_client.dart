/// One HTTP client for the app, and one view of it per extension (§2.7, §3.5).
///
/// "Network requests made by extensions go through a single `NetworkService` that owns the cookie
/// jars and rate limiters." This is that service: one transport for the whole app, and a
/// [SourceHttpClient] per extension that carries its own cookie jar and its own rate limiters, so
/// one source can neither read another's session nor spend another's budget.
///
/// **What it decides, not the extension.** The User-Agent, the timeouts, how large a body may be,
/// how many redirects to follow, and how often a host may be asked. An extension asks for a URL and
/// gets an answer; everything about how politely it was asked belongs to the app.
///
/// **Redirects are followed by hand**, one hop at a time, so that the caller sees every URL before
/// it is fetched. That is what lets the http bridge hold every hop to the extension's declared
/// domains: a site that redirects to another host must have declared that host too, or the request
/// stops there.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cookies.dart';
import 'rate_limiter.dart';

/// The methods an extension may use (SourceAPI 1.0's `HttpRequest`).
enum HttpMethod { get, post }

/// What to ask for.
final class NetworkRequest {
  const NetworkRequest({
    required this.url,
    this.method = HttpMethod.get,
    this.headers = const {},
    this.body,
  });

  final Uri url;
  final HttpMethod method;

  /// Headers as the caller wants them sent. The client adds its own where these leave a gap.
  final Map<String, String> headers;

  /// A body, which only a POST may carry.
  final String? body;
}

/// What came back.
final class NetworkResponse {
  const NetworkResponse({
    required this.status,
    required this.url,
    required this.headers,
    required this.body,
  });

  /// Any status, including 404 and 500: the contract returns them rather than throwing.
  final int status;

  /// The URL the body came from, after redirects.
  final Uri url;

  /// Header names in lower case; repeated headers joined with `, `.
  final Map<String, String> headers;

  final Uint8List body;
}

/// The request never got an answer: the connection failed, or it took too long.
///
/// Only this is a `Network` error in the contract's terms. A 404 or a 500 is an answer.
final class NetworkFailure implements Exception {
  const NetworkFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The answer was too large, or could not be followed any further.
///
/// A limit the app set was reached, rather than the network failing, so it is not a `Network`
/// error: the site answered, and the answer is one the app will not carry.
final class NetworkLimitReached implements Exception {
  const NetworkLimitReached(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the app decides for every request, whoever makes it.
final class NetworkPolicy {
  const NetworkPolicy({
    required this.userAgent,
    this.connectTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 30),
    this.maxBodyBytes = 10 * 1024 * 1024,
    this.maxRedirects = 5,
    this.minimumInterval = const Duration(milliseconds: 250),
    this.burstPerHost = 4,
    this.maxConcurrentPerHost = 4,
  });

  /// The one User-Agent the app sends. An extension cannot change it: it identifies the app to a
  /// site, and a source that lies about it speaks for every listener running it.
  final String userAgent;

  final Duration connectTimeout;

  /// How long one request, redirects included, may take before it is a failure.
  final Duration requestTimeout;

  /// The largest body that will be read. SourceAPI 1.0's limit is 10 MB.
  final int maxBodyBytes;

  final int maxRedirects;

  /// The sustained time between two requests to one host, per extension.
  final Duration minimumInterval;

  /// How many requests one extension may send to a host it has left alone before [minimumInterval]
  /// starts to hold it back. See [RateLimiter.burst].
  final int burstPerHost;

  /// How many requests to one host one extension may have in flight.
  final int maxConcurrentPerHost;
}

/// Checks a URL before it is fetched, and throws when it may not be.
///
/// The client calls it for the first URL and again for every redirect hop, because a redirect is a
/// URL the extension did not name. What counts as allowed is not the client's business: the http
/// bridge passes the extension's domains.
typedef UrlCheck = void Function(Uri url);

/// The app's one transport, and the maker of each extension's view of it.
final class NetworkService {
  /// The one transport is deliberately made once and kept for the life of the app. Dart's IO client
  /// pools its connections per origin and every request here asks for a persistent one, so a second
  /// request to a host it has already spoken to reuses the open TLS connection. A client made per
  /// request would pay for a new handshake every time, which on a mobile connection costs more than
  /// the answer does.
  NetworkService({required this.policy, http.Client? transport})
    : _transport = transport ?? http.Client();

  final NetworkPolicy policy;
  final http.Client _transport;

  final _clients = <String, SourceHttpClient>{};

  /// The client for [extensionId], made on first use and kept, because its cookies are its own.
  SourceHttpClient clientFor(String extensionId) =>
      _clients.putIfAbsent(extensionId, () => SourceHttpClient._(this));

  /// Forgets one extension's cookies and limiters, as uninstalling it should.
  void forget(String extensionId) => _clients.remove(extensionId);

  void close() {
    _transport.close();
    _clients.clear();
  }
}

/// One extension's view of the transport: its cookies, its rate limits.
final class SourceHttpClient {
  SourceHttpClient._(this._service) : cookies = CookieJar();

  /// For a test that wants a client without a service around it.
  factory SourceHttpClient.forTest({
    required NetworkPolicy policy,
    required http.Client transport,
  }) => NetworkService(
    policy: policy,
    transport: transport,
  ).clientFor('org.example.test');

  final NetworkService _service;

  /// This extension's cookies. Nothing else reads them.
  final CookieJar cookies;

  final _limiters = <String, RateLimiter>{};

  NetworkPolicy get policy => _service.policy;

  /// Sends [request], following redirects by hand and checking every hop.
  ///
  /// Throws [NetworkFailure] when nothing answered, and [NetworkLimitReached] when the answer
  /// broke one of the app's limits. Any status the site gives is returned.
  Future<NetworkResponse> send(NetworkRequest request, {UrlCheck? check}) {
    final limiter = _limiters.putIfAbsent(
      request.url.host.toLowerCase(),
      () => RateLimiter(
        minimumInterval: policy.minimumInterval,
        burst: policy.burstPerHost,
        maxConcurrent: policy.maxConcurrentPerHost,
      ),
    );
    return limiter.run(
      () => _send(request, check).timeout(
        policy.requestTimeout,
        onTimeout: () => throw NetworkFailure(
          'no answer from ${request.url.host} within '
          '${policy.requestTimeout.inSeconds} s',
        ),
      ),
    );
  }

  Future<NetworkResponse> _send(NetworkRequest request, UrlCheck? check) async {
    var url = request.url;
    var method = request.method;
    var body = request.body;
    for (var hop = 0; ; hop++) {
      check?.call(url);
      final response = await _once(url, method, body, request.headers);
      final location = response.headers['location'];
      if (!_isRedirect(response.statusCode) || location == null) {
        return _read(url, response);
      }
      if (hop >= policy.maxRedirects) {
        // Draining matters: an undrained stream keeps the connection open.
        await response.stream.drain<void>();
        throw NetworkLimitReached(
          '${request.url} redirected more than ${policy.maxRedirects} times',
        );
      }
      await response.stream.drain<void>();
      final next = Uri.tryParse(location);
      if (next == null) {
        throw NetworkFailure('$url redirected to something that is not a URL');
      }
      url = url.resolveUri(next);
      // 303, and 301 and 302 as every client treats them, turn a POST into a GET; 307 and 308 keep
      // the method and the body.
      if (response.statusCode != 307 && response.statusCode != 308) {
        method = HttpMethod.get;
        body = null;
      }
    }
  }

  static bool _isRedirect(int status) =>
      const {301, 302, 303, 307, 308}.contains(status);

  Future<http.StreamedResponse> _once(
    Uri url,
    HttpMethod method,
    String? body,
    Map<String, String> headers,
  ) async {
    final outgoing =
        http.Request(method == HttpMethod.get ? 'GET' : 'POST', url)
          ..followRedirects = false
          ..persistentConnection = true;
    outgoing.headers['user-agent'] = policy.userAgent;
    final cookie = cookies.headerFor(url);
    if (cookie != null) outgoing.headers['cookie'] = cookie;
    // The caller's headers win, so an extension can send the Cookie or Accept a site insists on.
    // The User-Agent is the app's and is put back below.
    outgoing.headers.addAll({
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    });
    outgoing.headers['user-agent'] = policy.userAgent;
    if (body != null) outgoing.body = body;
    final http.StreamedResponse response;
    try {
      response = await _service._transport
          .send(outgoing)
          .timeout(
            policy.connectTimeout,
            onTimeout: () => throw NetworkFailure(
              'no answer from ${url.host} within '
              '${policy.connectTimeout.inSeconds} s',
            ),
          );
    } on NetworkFailure {
      rethrow;
    } catch (error) {
      // A socket that would not open, a name that would not resolve, a handshake that failed:
      // nothing answered, which is the one case the contract calls Network.
      throw NetworkFailure('could not reach ${url.host}: $error');
    }
    final setCookies = response.headersSplitValues['set-cookie'] ?? const [];
    cookies.storeFromResponse(url, setCookies);
    return response;
  }

  Future<NetworkResponse> _read(Uri url, http.StreamedResponse response) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      if (bytes.length > policy.maxBodyBytes) {
        throw NetworkLimitReached(
          'the answer from ${url.host} is larger than '
          '${policy.maxBodyBytes ~/ (1024 * 1024)} MB',
        );
      }
    }
    return NetworkResponse(
      status: response.statusCode,
      url: url,
      headers: Map.unmodifiable(response.headers),
      body: bytes.takeBytes(),
    );
  }
}
