import 'package:flutter/material.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';

import 'sources/extension_console.dart';

/// The extension console (§3.5, §3.11): what extensions wrote, and what the app wrote about them.
///
/// Newest first, because the line that matters is the one that just happened. Each line says which
/// extension it belongs to and whether the app or the extension wrote it, so an author is never left
/// wondering whose sentence they are reading.
class ExtensionConsoleView extends StatelessWidget {
  const ExtensionConsoleView({
    super.key,
    required this.lines,
    this.only,
    this.emptyMessage =
        'Nothing yet. What an extension logs, and anything that goes wrong '
        'with one, shows up here.',
  });

  /// Every line to show, oldest first, as the console keeps them.
  final List<ExtensionLogLine> lines;

  /// The extension whose lines these are, when the console was opened for one.
  final String? only;

  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(emptyMessage, textAlign: TextAlign.center),
        ),
      );
    }
    final newestFirst = lines.reversed.toList();
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: newestFirst.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) =>
          _Line(line: newestFirst[index], showExtension: only == null),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.line, required this.showExtension});

  final ExtensionLogLine line;
  final bool showExtension;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (icon, colour) = switch (line.level) {
      ExtensionLogLevel.error => (Icons.error_outline, colors.error),
      ExtensionLogLevel.warn => (Icons.warning_amber_outlined, colors.tertiary),
      ExtensionLogLevel.info => (Icons.info_outline, colors.onSurfaceVariant),
      ExtensionLogLevel.debug => (
        Icons.bug_report_outlined,
        colors.onSurfaceVariant,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: colour),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    _clockTime(line.at),
                    if (showExtension) line.extensionId,
                    if (line.fromTheApp) 'Kikuyomi',
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  line.text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier'],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The local time a line was written, to the second.
///
/// Deliberately not a localised time: this is a log read while something is being fixed, where lining
/// two lines up matters more than reading the hour the way this device usually writes it.
String _clockTime(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// The console as one piece of text, for pasting into a bug report.
///
/// The console is the only place a failure inside an extension is written down, so getting it out of
/// the app has to be one tap; an author on a phone cannot read a log they cannot copy.
String consoleAsText(List<ExtensionLogLine> lines) => [
  for (final line in lines)
    '${line.at.toIso8601String()} ${line.level.name.toUpperCase()} '
        '${line.extensionId}${line.fromTheApp ? ' (Kikuyomi)' : ''}: '
        '${line.text}',
].join('\n');
