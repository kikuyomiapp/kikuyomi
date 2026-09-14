import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart' show PlayerReady;

import 'player_view.dart';

/// The player screen's keyboard shortcuts, the ones §2.6 promises desktop: space plays or pauses,
/// the left and right arrows skip back and forward as the skip buttons do, and the square brackets
/// step down and up through [PlayerView.speeds], stopping at either end.
///
/// Nothing here asks which platform it runs on. The keys come from whatever keyboard there is, and
/// a phone without one never sends them.
///
/// Pure, like [PlayerView]: it reports what the keys ask for. It belongs around the whole screen,
/// app bar included, so that every control on the screen is inside it:
///
/// * It holds focus itself, taken as the screen opens, so the keys work before anything is clicked.
/// * It is a focus scope, so when a focused control leaves the screen, focus falls back here rather
///   than to the route above it, out of the keys' reach.
/// * A key travels up from the focused control, and the app binds space to pressing that control
///   further up than this, so here space plays or pauses and presses nothing. Enter still does.
class PlayerShortcuts extends StatelessWidget {
  const PlayerShortcuts({
    super.key,
    required this.state,
    required this.onPlayPause,
    required this.onSkip,
    required this.onSpeed,
    required this.child,
  });

  /// The open book, or null while none is ready, when the keys do nothing and pass on.
  final PlayerReady? state;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSkip;
  final ValueChanged<double> onSpeed;
  final Widget child;

  /// The first activator here that accepts a key decides what the key does.
  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
        _PlayPauseIntent(),
    // Space held down repeats. The repeats neither play and pause again nor fall through to press
    // the focused control.
    SingleActivator(LogicalKeyboardKey.space):
        DoNothingAndStopPropagationIntent(),
    SingleActivator(LogicalKeyboardKey.arrowLeft): _SkipIntent(forward: false),
    SingleActivator(LogicalKeyboardKey.arrowRight): _SkipIntent(forward: true),
    // By the character typed rather than the key pressed, so a layout that puts the brackets behind
    // Shift works too.
    CharacterActivator('[', includeRepeats: false): _StepSpeedIntent(
      faster: false,
    ),
    CharacterActivator(']', includeRepeats: false): _StepSpeedIntent(
      faster: true,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    return Shortcuts(
      shortcuts: state == null ? const {} : _shortcuts,
      child: Actions(
        actions: {
          _PlayPauseIntent: CallbackAction<_PlayPauseIntent>(
            onInvoke: (_) {
              onPlayPause();
              return null;
            },
          ),
          _SkipIntent: CallbackAction<_SkipIntent>(
            onInvoke: (intent) {
              onSkip(
                intent.forward
                    ? PlayerView.skipInterval
                    : -PlayerView.skipInterval,
              );
              return null;
            },
          ),
          _StepSpeedIntent: CallbackAction<_StepSpeedIntent>(
            onInvoke: (intent) {
              final speed = state == null
                  ? null
                  : _steppedSpeed(state.speed, faster: intent.faster);
              if (speed != null) onSpeed(speed);
              return null;
            },
          ),
        },
        child: FocusScope(autofocus: true, child: child),
      ),
    );
  }
}

/// The preset one step faster or slower than [speed], or null when there is none that way. A speed
/// between presets steps to the nearest preset in that direction.
double? _steppedSpeed(double speed, {required bool faster}) {
  final presets = faster ? PlayerView.speeds : PlayerView.speeds.reversed;
  for (final preset in presets) {
    if (faster ? preset > speed : preset < speed) return preset;
  }
  return null;
}

class _PlayPauseIntent extends Intent {
  const _PlayPauseIntent();
}

class _SkipIntent extends Intent {
  const _SkipIntent({required this.forward});

  final bool forward;
}

class _StepSpeedIntent extends Intent {
  const _StepSpeedIntent({required this.faster});

  final bool faster;
}
