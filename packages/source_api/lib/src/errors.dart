/// How a source call fails: SourceAPI 1.0's error kinds, one class each.
///
/// The app reacts to the kind rather than only showing the message (§3.4): it offers a browser for
/// a challenge, backs off and pauses a source's download queue when rate limited, marks a book
/// unavailable when it is gone, and counts network and parse failures towards an extension's
/// health. Anything an extension throws that is not one of these kinds, including a plain `Error`
/// and a kind added by a later minor version, arrives as [ParseException], so adding kinds stays
/// additive.
///
/// Every method of a `ContentSource` fails with one of these, whether it is an extension behind the
/// JavaScript adapter or a built-in source.
library;

/// A source call failed.
sealed class SourceException implements Exception {
  const SourceException([this.message = '']);

  /// What went wrong, for the extension console and for diagnostics. It comes from the extension,
  /// so it is never shown to the listener as an explanation on its own.
  final String message;

  /// The kind, as the contract and the extension SDK name it.
  String get kind;

  @override
  String toString() => message.isEmpty ? kind : '$kind: $message';
}

/// The site wants a check in a browser, such as an anti-bot challenge.
///
/// In 1.0 the app tells the listener and offers to open [url]; the in-app WebView flow arrives with
/// API 1.x (ADR-0016).
final class ChallengeRequiredException extends SourceException {
  const ChallengeRequiredException(this.url, [super.message]);

  /// The page to open. On one of the extension's declared domains, like every other URL.
  final Uri url;

  @override
  String get kind => 'ChallengeRequired';

  @override
  String toString() => '${super.toString()} ($url)';
}

/// The source needs a login the app cannot offer yet. Login arrives with source settings in API 1.x.
final class LoginRequiredException extends SourceException {
  const LoginRequiredException([super.message]);

  @override
  String get kind => 'LoginRequired';
}

/// The site is refusing requests for now. The app backs off and pauses that source's downloads.
final class RateLimitedException extends SourceException {
  const RateLimitedException({String message = '', this.retryAfterMs})
    : super(message);

  /// How long to wait before asking again, in milliseconds, when the source says.
  final int? retryAfterMs;

  @override
  String get kind => 'RateLimited';

  @override
  String toString() => retryAfterMs == null
      ? super.toString()
      : '${super.toString()} (retry after ${retryAfterMs}ms)';
}

/// The book or chapter is not at the source any more.
final class NotFoundException extends SourceException {
  const NotFoundException([super.message]);

  @override
  String get kind => 'NotFound';
}

/// The site changed in a way the extension cannot follow. The app suggests updating the extension.
final class SourceOutdatedException extends SourceException {
  const SourceOutdatedException([super.message]);

  @override
  String get kind => 'SourceOutdated';
}

/// The request never reached the site. The app retries with backoff.
final class NetworkException extends SourceException {
  const NetworkException([super.message]);

  @override
  String get kind => 'Network';
}

/// The source's answer could not be read, or broke one of the contract's rules.
///
/// Also what anything else an extension throws becomes. The message names the field and what is
/// wrong with it, because extension authors read these in the console.
final class ParseException extends SourceException {
  const ParseException([super.message]);

  @override
  String get kind => 'Parse';
}
