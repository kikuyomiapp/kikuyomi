import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:smtc_windows/smtc_windows.dart';

/// The system's media controls on Windows, through the System Media Transport Controls (§6.5): the
/// keyboard's media keys, the media tile in the volume flyout, and the buttons of Bluetooth
/// headphones.
///
/// `audio_service` has no Windows implementation, so Windows has this bridge of its own, and
/// `SystemMediaControls` chooses it there. It is not exported: the composition root asks for the
/// controls through `SystemMediaControls`, and the seam below speaks the plugin's types.
///
/// **Next and previous skip by the interval; they do not change chapter.** The flyout shows only
/// previous, play or pause, and next, and a keyboard's media keys send the same three plus stop, so
/// Windows offers no second pair of buttons to carry the other meaning. Appendix A defaults a lock
/// screen to skip intervals, the Android notification shows the same, and a stray press of a media
/// key then costs 30 seconds instead of the rest of a chapter. Chapter navigation stays on the
/// player screen. Fast-forward and rewind, which some remotes send, skip as well.
///
/// **The timeline is shown but cannot be dragged to seek.** `smtc_windows` subscribes to SMTC's
/// position-change requests only through an internal API, so no [MediaSeek] comes from Windows.
final class SmtcBridge implements MediaSessionBridge {
  @visibleForTesting
  SmtcBridge(this._controls);

  /// Loads the plugin's native library and creates the controls, hidden until a book is open.
  /// Call once, at start.
  static Future<SmtcBridge> start() async {
    await SMTCWindows.initialize();
    return SmtcBridge(
      _PluginControls(SMTCWindows(config: _buttons, enabled: false)),
    );
  }

  /// SMTC raises a button only if it is enabled, so every button the bridge answers is.
  static const _buttons = SMTCConfig(
    playEnabled: true,
    pauseEnabled: true,
    stopEnabled: true,
    nextEnabled: true,
    prevEnabled: true,
    fastForwardEnabled: true,
    rewindEnabled: true,
  );

  final SmtcControls _controls;

  /// The newest state asked for, and how many updates have been asked for and applied.
  ///
  /// Each SMTC call is asynchronous, and `smtc_windows` runs them on a thread pool, so two calls
  /// made back to back can land in either order: hiding the controls and showing them again could
  /// leave them hidden. Updates are therefore applied one at a time, and an update asked for while
  /// another is being applied replaces any still waiting, since each state is complete in itself.
  MediaSessionState? _wanted;
  int _asked = 0;
  int _applied = 0;
  bool _applying = false;

  /// What the controls were last sent, so that an update sends only what changed. Null while they
  /// are hidden.
  _Shown? _shown;

  /// Whether a failed update left the controls in a state nobody knows, so that the next update
  /// sends everything, or hides them, whatever [_shown] says.
  bool _uncertain = false;

  @override
  Stream<MediaCommand> get commands =>
      _controls.buttons.expand((button) => [?_commandFor(button)]);

  @override
  void update(MediaSessionState? state) {
    _wanted = state;
    _asked++;
    if (!_applying) unawaited(_applyWanted());
  }

  Future<void> _applyWanted() async {
    _applying = true;
    while (_applied < _asked) {
      final asked = _asked;
      try {
        await _apply(_wanted);
      } catch (error, stack) {
        // The controls are a convenience: a failure is reported, and must never reach playback.
        _shown = null;
        _uncertain = true;
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'kikuyomi_platform_adapters',
            context: ErrorDescription(
              'while updating the Windows media controls',
            ),
          ),
        );
      }
      _applied = asked;
    }
    _applying = false;
  }

  Future<void> _apply(MediaSessionState? state) async {
    final shown = _uncertain ? null : _shown;
    if (state == null) {
      if (shown == null && !_uncertain) return;
      _shown = null;
      await _controls.setPlaybackStatus(PlaybackStatus.closed);
      // Off before emptied, so the flyout never shows a blank tile.
      await _controls.disable();
      await _controls.clearMetadata();
      _uncertain = false;
      return;
    }
    final next = _Shown.of(state);
    _shown = next;
    if (next.metadata != shown?.metadata) {
      await _controls.updateMetadata(next.metadata);
    }
    if (next.timeline != shown?.timeline) {
      await _controls.updateTimeline(next.timeline);
    }
    if (next.status != shown?.status) {
      await _controls.setPlaybackStatus(next.status);
    }
    // On after filled, so the flyout never shows a blank tile.
    if (shown == null) await _controls.enable();
    _uncertain = false;
  }

  /// What a button asks of the book, or null for the buttons an audiobook has no use for.
  static MediaCommand? _commandFor(PressedButton button) => switch (button) {
    PressedButton.play => const MediaPlay(),
    PressedButton.pause => const MediaPause(),
    // An audiobook pauses rather than forgetting where it was, as on Android.
    PressedButton.stop => const MediaPause(),
    PressedButton.next || PressedButton.fastForward => const MediaSkipForward(),
    PressedButton.previous || PressedButton.rewind => const MediaSkipBackward(),
    PressedButton.record ||
    PressedButton.channelUp ||
    PressedButton.channelDown => null,
  };
}

/// What the controls show for one [MediaSessionState], in the plugin's terms.
final class _Shown {
  const _Shown({
    required this.metadata,
    required this.timeline,
    required this.status,
  });

  factory _Shown.of(MediaSessionState state) {
    final durationMs = state.durationMs < 0 ? 0 : state.durationMs;
    return _Shown(
      metadata: MusicMetadata(
        title: state.title,
        album: state.album,
        // The plugin leaves a field it is given no value for as it was, so an author the book lacks
        // is sent blank, or the previous book's would linger.
        artist: state.artist ?? '',
      ),
      // The plugin turns milliseconds into unsigned durations, so nothing negative may reach it.
      // The seek range is left unset, which leaves nothing to seek to: see [SmtcBridge].
      timeline: PlaybackTimeline(
        startTimeMs: 0,
        endTimeMs: durationMs,
        positionMs: state.positionMs.clamp(0, durationMs),
      ),
      // SMTC has no buffering of its own beside its play and pause status: its `changing` status
      // replaces them, and would flicker the flyout's play button at every skip. A book that is
      // buffering while it plays shows as playing.
      status: state.playing ? PlaybackStatus.playing : PlaybackStatus.paused,
    );
  }

  final MusicMetadata metadata;
  final PlaybackTimeline timeline;
  final PlaybackStatus status;
}

/// The SMTC operations the bridge performs: a seam, so that what it sends can be tested without a
/// Windows media session.
@visibleForTesting
abstract interface class SmtcControls {
  Stream<PressedButton> get buttons;
  Future<void> enable();
  Future<void> disable();
  Future<void> updateMetadata(MusicMetadata metadata);
  Future<void> clearMetadata();
  Future<void> updateTimeline(PlaybackTimeline timeline);
  Future<void> setPlaybackStatus(PlaybackStatus status);
}

final class _PluginControls implements SmtcControls {
  _PluginControls(this._smtc);

  final SMTCWindows _smtc;

  @override
  Stream<PressedButton> get buttons => _smtc.buttonPressStream;

  @override
  Future<void> enable() => _smtc.enableSmtc();

  @override
  Future<void> disable() => _smtc.disableSmtc();

  @override
  Future<void> updateMetadata(MusicMetadata metadata) =>
      _smtc.updateMetadata(metadata);

  @override
  Future<void> clearMetadata() => _smtc.clearMetadata();

  @override
  Future<void> updateTimeline(PlaybackTimeline timeline) =>
      _smtc.updateTimeline(timeline);

  @override
  Future<void> setPlaybackStatus(PlaybackStatus status) =>
      _smtc.setPlaybackStatus(status);
}
