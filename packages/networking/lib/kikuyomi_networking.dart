/// HTTP client abstraction, per-extension cookie jars, rate limiting and caching.
///
/// Platform HTTP clients are injected rather than imported, which is what keeps this package free
/// of Flutter (§2.4). What it holds is the app's one transport (§2.7's `NetworkService`), the view
/// of it each extension gets, and the rules the app keeps to itself: the User-Agent, the timeouts,
/// how large a body may be and how often a host may be asked.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/cookies.dart';
export 'src/http_client.dart';
export 'src/rate_limiter.dart';
