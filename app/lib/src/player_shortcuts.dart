import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart' show PlayerReady;

import 'player_view.dart';

/// The player screen's keyboard shortcuts, the ones §2.6 promises desktop: space plays or pauses,
/// the left and right arrows skip back and forward as the skip buttons do, and the square brackets
/// step down and up through [PlayerView.speeds], stopping at either end. B adds a bookmark, as the
/// bookmark button does, except while a text field has focus, where a B is typed.
///
/// Nothing here asks which platform it runs on. The keys come from whatever keyboard there is, and
/// a phone without one never sends them.
///
/// Pure, like [PlayerView]: it reports what the keys ask for. It belongs around the whole screen,
/// app bar included, so that every control on the screen is inside it:
///
/// * It holds focus itself, taken as the screen opens, so the keys work before anything is clicked.
/// * It is a focus scope. Focus that a control on the screen lets go of with nowhere earlier to
///   return to, as unfocusing it does, lands here rather than on the route above, out of the keys'
///   reach.
/// * A key travels up from the focused control, and the app binds space to pressing that control
///   further up than this, so here space plays or pauses and presses nothing. Enter still does.
class PlayerShortcuts extends StatelessWidget {
  const PlayerShortcuts({
    super.key,
    required this.state,
    required this.onPlayPause,
    required this.onSkip,
    required this.onSpeed,
    required this.onAddBookmark,
    required this.child,
  });

  /// The open book, or null while none is ready, when the keys do nothing and pass on.
  final PlayerReady? state;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSkip;
  final ValueChanged<double> onSpeed;
  final VoidCallback onAddBookmark;
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
    // By the key rather than the character, unlike the brackets: a letter is where every layout
    // puts it, and a keyboard typing another alphabet, or with Caps Lock on, still reports the key
    // as B. Held down, it adds one bookmark rather than one for every repeat.
    SingleActivator(LogicalKeyboardKey.keyB, includeRepeats: false):
        _AddBookmarkIntent(),
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
          _AddBookmarkIntent: _UnlessTyping<_AddBookmarkIntent>(
            onInvoke: (_) {
              onAddBookmark();
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

class _AddBookmarkIntent extends Intent {
  const _AddBookmarkIntent();
}

/// A [CallbackAction] that stands aside while a text field has focus, for a key that is also typed.
///
/// A key reaches these shortcuts before the platform turns it into text, and one they handle is
/// never typed. An action that is not enabled leaves its key unhandled, so it goes on to the text
/// field as typing.
class _UnlessTyping<T extends Intent> extends CallbackAction<T> {
  _UnlessTyping({required super.onInvoke});

  @override
  bool isEnabled(T intent) =>
      primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() ==
      null;
}
