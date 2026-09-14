import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';

/// The system's media controls through `audio_service` (§6.5).
///
/// On Android: the media notification, lock screen and Bluetooth buttons, backed by the foreground
/// service that keeps playback alive in the background. On iOS: Now Playing and the remote
/// commands.
///
/// `audio_service` has no Windows implementation and quietly does nothing there, so
/// `SystemMediaControls` starts this bridge only on the other platforms. §6.5 gives Windows its
/// controls through SMTC, in `SmtcBridge`.
final class AudioServiceBridge implements MediaSessionBridge {
  AudioServiceBridge._(this._handler);

  /// Starts the service. Call once, at start. The skip buttons move by [skipInterval].
  static Future<AudioServiceBridge> start({
    required Duration skipInterval,
  }) async {
    final handler = await AudioService.init(
      builder: _Handler.new,
      config: AudioServiceConfig(
        // Notification channel ids are scoped to the app, so this one needs no application id.
        androidNotificationChannelId: 'playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationOngoing: true,
        fastForwardInterval: skipInterval,
        rewindInterval: skipInterval,
      ),
    );
    return AudioServiceBridge._(handler);
  }

  final _Handler _handler;

  @override
  Stream<MediaCommand> get commands => _handler.commands.stream;

  @override
  void update(MediaSessionState? state) {
    if (state == null) {
      _handler.mediaItem.add(null);
      _handler.playbackState.add(PlaybackState());
      return;
    }
    _handler.mediaItem.add(
      MediaItem(
        id: '${state.album}\n${state.title}',
        title: state.title,
        album: state.album,
        artist: state.artist,
        duration: Duration(milliseconds: state.durationMs),
      ),
    );
    _handler.playbackState.add(
      PlaybackState(
        processingState: state.buffering
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: state.playing,
        // Appendix A: a lock screen shows skip-interval buttons or track buttons, not both, and an
        // audiobook wants the intervals.
        controls: [
          MediaControl.rewind,
          if (state.playing) MediaControl.pause else MediaControl.play,
          MediaControl.fastForward,
        ],
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: const {MediaAction.seek},
        updatePosition: Duration(milliseconds: state.positionMs),
        speed: state.speed,
        updateTime: state.updatedAt,
      ),
    );
  }
}

/// Turns what the system asks `audio_service` for into [MediaCommand]s. It plays nothing itself:
/// the coordinator does, once the command reaches it.
final class _Handler extends BaseAudioHandler {
  final commands = StreamController<MediaCommand>.broadcast();

  @override
  Future<void> play() async => commands.add(const MediaPlay());

  @override
  Future<void> pause() async => commands.add(const MediaPause());

  /// The notification being dismissed, or a stop from a device. An audiobook pauses rather than
  /// forgetting where it was.
  @override
  Future<void> stop() async => commands.add(const MediaPause());

  @override
  Future<void> fastForward() async => commands.add(const MediaSkipForward());

  @override
  Future<void> rewind() async => commands.add(const MediaSkipBackward());

  @override
  Future<void> seek(Duration position) async =>
      commands.add(MediaSeek(position.inMilliseconds));

  @override
  Future<void> skipToNext() async => commands.add(const MediaNextChapter());

  @override
  Future<void> skipToPrevious() async =>
      commands.add(const MediaPreviousChapter());

  /// A headset's buttons.
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async =>
      commands.add(switch (button) {
        MediaButton.media => const MediaPlayPause(),
        MediaButton.next => const MediaNextChapter(),
        MediaButton.previous => const MediaPreviousChapter(),
      });
}
