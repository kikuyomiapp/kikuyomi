import 'package:kikuyomi_extension_manager/kikuyomi_extension_manager.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';

import 'source_registry.dart';

/// A source failure, in words a listener can act on.
///
/// SourceAPI 1.0's Errors table says the app "reacts to each kind rather than just showing its
/// message", and the extension's own message is explicitly not an explanation: it comes from a third
/// party and is written for whoever is debugging the extension. So every kind gets a sentence of the
/// app's own, and the extension's words go underneath as [detail], where they help a bug report and
/// mislead nobody.
final class SourceProblem {
  const SourceProblem({
    required this.message,
    this.detail,
    this.canRetry = false,
    this.openInBrowser,
  });

  /// What went wrong and what it means for the listener.
  final String message;

  /// The extension's own words, or the loader's, for the console and for a bug report. Never the
  /// explanation on its own.
  final String? detail;

  /// Whether trying again might work. False for a book that is gone, and for anything that needs a
  /// browser, a login or an update first.
  final bool canRetry;

  /// A page to open in the device's browser, for a challenge the app cannot answer in 1.0.
  final Uri? openInBrowser;
}

/// [error] as something to show, for a failure from the source called [sourceName].
///
/// Everything a source call can fail with is here: the seven error kinds, the extension refusing to
/// load, and whatever else may reach a screen, which is treated as an unexpected failure rather than
/// swallowed. No screen may end up empty with no word about why (§3.4).
SourceProblem describeSourceProblem(
  Object error, {
  required String sourceName,
}) {
  return switch (error) {
    RateLimitedException(:final retryAfterMs, :final message) => SourceProblem(
      message: retryAfterMs == null
          ? '$sourceName is asking for a pause. Try again in a moment.'
          : '$sourceName is asking for a pause. Try again in '
                '${_roughly(retryAfterMs)}.',
      detail: _detail(message),
      canRetry: true,
    ),
    NetworkException(:final message) => SourceProblem(
      message:
          'Could not reach $sourceName. Check your connection and try again.',
      detail: _detail(message),
      canRetry: true,
    ),
    ParseException(:final message) => SourceProblem(
      message:
          'Kikuyomi could not read what $sourceName sent. The site may have '
          'changed.',
      detail: _detail(message),
      canRetry: true,
    ),
    NotFoundException(:final message) => SourceProblem(
      message: '$sourceName no longer has this.',
      detail: _detail(message),
    ),
    SourceOutdatedException(:final message) => SourceProblem(
      message:
          'The $sourceName extension no longer matches the site and needs '
          'updating.',
      detail: _detail(message),
    ),
    // The two SourceAPI 1.0 leaves to 1.x (ADR-0016). Both are told plainly rather than retried,
    // because retrying cannot help and a spinner that never ends is worse than a sentence.
    ChallengeRequiredException(:final url, :final message) => SourceProblem(
      message:
          '$sourceName wants a check in a browser before it will answer. '
          'Kikuyomi cannot show that yet, so open the page, pass the check, and '
          'come back.',
      detail: _detail(message),
      openInBrowser: url,
    ),
    LoginRequiredException(:final message) => SourceProblem(
      message:
          '$sourceName needs you to sign in, and Kikuyomi cannot sign in to a '
          'source yet.',
      detail: _detail(message),
    ),
    // §3.9's stub source: the extension was removed and the books it brought are still here. Nothing
    // to retry, and one thing that helps, so the message says that thing.
    ExtensionMissingException() => SourceProblem(
      message:
          'The $sourceName extension is not installed. Install it again to use '
          'this source; your books, their progress and your bookmarks were '
          'kept.',
    ),
    ExtensionLoadException(:final message) => SourceProblem(
      message: 'The $sourceName extension could not be loaded.',
      detail: message,
    ),
    ManifestException(:final message) => SourceProblem(
      message: 'The $sourceName extension could not be read.',
      detail: message,
    ),
    UnsupportedError(:final message) => SourceProblem(
      message: '$sourceName cannot do that yet.',
      detail: message?.toString(),
    ),
    _ => SourceProblem(
      message: 'Something went wrong with $sourceName.',
      detail: '$error',
      canRetry: true,
    ),
  };
}

String? _detail(String message) => message.trim().isEmpty ? null : message;

/// A wait a person would say out loud, rather than a figure in milliseconds.
String _roughly(int milliseconds) {
  final seconds = (milliseconds / 1000).ceil();
  if (seconds <= 1) return 'a second';
  if (seconds < 60) return '$seconds seconds';
  final minutes = (seconds / 60).ceil();
  return minutes == 1 ? 'a minute' : '$minutes minutes';
}

/// One line about [error], for a snack bar where a whole [SourceProblem] would not fit.
String describeSourceProblemBriefly(
  Object error, {
  required String sourceName,
}) => describeSourceProblem(error, sourceName: sourceName).message;
