import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';

/// Whether this platform reports files dropped onto the window as paths the app can read where they
/// are.
///
/// `desktop_drop` reports paths on Windows, macOS and Linux. Its Android implementation, still a
/// preview, reports content addresses that plain file access cannot open, as the Android folder
/// picker does, and it has no iOS implementation at all. The app reads this as
/// `StorageLocations.acceptsDroppedFiles`.
final bool platformReportsDroppedPaths =
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Takes files and folders dragged onto the window from the system's file manager: the
/// drag-and-drop §2.6 promises desktop, and one of the ways §3.10's Local source takes folders.
///
/// It wraps [child] and reports something dragged over it, the drag leaving, and the paths of what
/// was dropped. Where the platform does not report dropped files as paths it is [child] and nothing
/// more, so a phone never creates a drop target.
///
/// The platform reports a drag over the window whatever is shown there, so a target below a route
/// pushed over it would take drops meant for that route. Disable it with [enabled] while it is
/// covered. A disabled target stays in the tree, so switching it off and on again keeps the state of
/// everything below it.
///
/// The plugin's types stay behind this widget: callers see only callbacks and paths.
class FileDropTarget extends StatelessWidget {
  const FileDropTarget({
    super.key,
    this.enabled = true,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDropped,
    required this.child,
  });

  /// Whether drops are taken. While false nothing is reported, and a drag that was over the target
  /// when it was disabled is reported as having left.
  final bool enabled;

  /// Something is being dragged over the target.
  final VoidCallback onDragEntered;

  /// What was dragged over the target left it, or was dropped on it, or the target was disabled
  /// under it. On a drop this comes first, then [onDropped].
  final VoidCallback onDragExited;

  /// Something was dropped on the target: the absolute paths of the files and folders dropped, in
  /// the order the platform lists them. Empty when what was dropped was not files, such as text
  /// dragged from a browser.
  final ValueChanged<List<String>> onDropped;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!platformReportsDroppedPaths) return child;
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) => onDragEntered(),
      onDragExited: (_) => onDragExited(),
      onDragDone: (details) =>
          onDropped([for (final item in details.files) item.path]),
      child: child,
    );
  }
}
