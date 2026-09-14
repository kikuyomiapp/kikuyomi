import 'package:flutter/material.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart'
    show FileDropTarget;

/// Takes audiobooks dropped anywhere on [child], a whole screen, and while something is dragged
/// over it shows that dropping it there adds it.
///
/// It takes drops only while its screen is the one shown. The platform reports a drag over the
/// window whatever is on top, and a drop on the player or on the "Add book" sheet was not aimed at
/// the library.
///
/// It reports what was dropped and adds nothing itself, so it is tested without a database.
class BookDropZone extends StatefulWidget {
  const BookDropZone({
    super.key,
    required this.enabled,
    required this.onDropped,
    required this.child,
  });

  /// Whether this device takes dropped files at all, as `StorageLocations.acceptsDroppedFiles`
  /// says.
  final bool enabled;

  /// Something was dropped: the paths of the files and folders dropped, possibly none.
  final ValueChanged<List<String>> onDropped;

  final Widget child;

  @override
  State<BookDropZone> createState() => _BookDropZoneState();
}

class _BookDropZoneState extends State<BookDropZone> {
  var _dragging = false;

  void _setDragging(bool dragging) {
    if (dragging != _dragging) setState(() => _dragging = dragging);
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilt whenever a route is pushed over the screen or popped off it. Outside any route, as
    // when a test shows the zone on its own, it counts as shown.
    final active = widget.enabled && (ModalRoute.isCurrentOf(context) ?? true);
    // A drag under a screen opened over this one is over. The drop target says so as it is
    // disabled, but the overlay must not rely on that, or a drag the platform never reported as
    // leaving would leave the library covered once that screen closes.
    if (!active) _dragging = false;
    return FileDropTarget(
      enabled: active,
      onDragEntered: () => _setDragging(true),
      onDragExited: () => _setDragging(false),
      onDropped: widget.onDropped,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_dragging) const Positioned.fill(child: _DropOverlay()),
        ],
      ),
    );
  }
}

/// What covers the screen while something is dragged over it.
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // A drag from the file manager moves no pointer the app sees, so the overlay never needs to
    // take one; ignoring them keeps a stray hover from reaching it.
    return IgnorePointer(
      // Material, since the overlay lies over the whole Scaffold rather than inside it, and text
      // needs a Material above it for its style.
      child: Material(
        color: colors.primaryContainer.withValues(alpha: 0.92),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.library_add_outlined,
                  size: 72,
                  color: colors.onPrimaryContainer,
                ),
                const SizedBox(height: 16),
                Text(
                  'Drop audiobooks to add them',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'M4B, M4A or MP3 files, or folders of audio files',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
