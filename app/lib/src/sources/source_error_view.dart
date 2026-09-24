import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../snack_bars.dart';
import 'source_problem.dart';

/// What a screen shows instead of a source's books when the source could not answer.
///
/// Every kind of failure lands here and every one says something: a spinner that stops, or a grid
/// that stays empty with no word about why, is the thing SourceAPI 1.0's Errors table exists to
/// prevent. Retrying is offered only where it could work, and a challenge offers the browser,
/// because that is the one thing that can get past it until the in-app flow arrives in API 1.x.
class SourceErrorView extends StatelessWidget {
  const SourceErrorView({
    super.key,
    required this.error,
    required this.sourceName,
    this.onRetry,
    this.compact = false,
  });

  final Object error;

  /// Named in the message, so a listener with several sources knows which one stopped.
  final String sourceName;

  /// Asks again. Offered only for the kinds that may answer differently next time.
  final Future<void> Function()? onRetry;

  /// True when the failure ends a list that already has books in it, where the message is a strip
  /// under them rather than the whole screen.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final problem = describeSourceProblem(error, sourceName: sourceName);
    final theme = Theme.of(context);
    final detail = problem.detail;
    final openInBrowser = problem.openInBrowser;
    final retry = onRetry;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: compact
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (!compact) ...[
          Icon(
            Icons.cloud_off_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
        ],
        Text(
          problem.message,
          textAlign: compact ? TextAlign.start : TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: compact ? TextAlign.start : TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (retry != null || openInBrowser != null) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              if (problem.canRetry && retry != null)
                FilledButton.tonal(
                  onPressed: () => retry(),
                  child: const Text('Try again'),
                ),
              if (openInBrowser != null)
                OutlinedButton.icon(
                  onPressed: () => _open(context, openInBrowser),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in browser'),
                ),
            ],
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(24),
      child: compact ? content : Center(child: content),
    );
  }
}

/// Opens [url] in the device's browser, saying so when nothing can.
Future<void> _open(BuildContext context, Uri url) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened) {
      tellInSnackBar(messenger, 'Could not open $url');
    }
  } catch (error) {
    tellInSnackBar(messenger, 'Could not open $url');
  }
}

/// Opens [url] in the device's browser from anywhere else, such as a book's "Open at the source".
Future<void> openInBrowser(BuildContext context, Uri url) =>
    _open(context, url);
