import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'extension_console_view.dart';
import 'providers.dart';
import 'snack_bars.dart';

/// The extension console (§3.11), for every extension or for one.
///
/// Watched rather than read once, so a line written while it is open appears as it is written: an
/// author presses a source, watches this, and sees what the extension did.
class ExtensionConsoleScreen extends ConsumerWidget {
  const ExtensionConsoleScreen({super.key, this.extensionId});

  /// The extension whose lines to show, or null for all of them.
  final String? extensionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(extensionConsoleProvider).value ?? const [];
    final id = extensionId;
    final lines = id == null
        ? all
        : [
            for (final line in all)
              if (line.extensionId == id) line,
          ];

    return Scaffold(
      appBar: AppBar(
        title: Text(id ?? 'Extension console'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy',
            onPressed: lines.isEmpty
                ? null
                : () => _copy(context, consoleAsText(lines)),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: all.isEmpty
                ? null
                : () => ref.read(servicesProvider).extensionConsole.clear(),
          ),
        ],
      ),
      body: ExtensionConsoleView(
        lines: lines,
        only: id,
        emptyMessage: id == null
            ? 'Nothing yet. What an extension logs, and anything that goes '
                  'wrong with one, shows up here.'
            : 'This extension has logged nothing yet.',
      ),
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    tellInSnackBar(messenger, 'Copied the console');
  }
}
