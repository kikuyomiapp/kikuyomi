import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';

/// The [PlaybackEngine] over `just_audio` (§6.2, ADR-0006): ExoPlayer on Android, AVPlayer on iOS,
/// and mpv through `just_audio_media_kit` on Windows.
///
/// Spike (b) measured two behaviours of the Windows backend that would each corrupt resume. The
/// [PlaybackEngine] contract states the rules that avoid them, and this is where they are kept:
///
/// - [load] positions the player with `setAudioSources`' initial index and position, never with a
///   seek, because a combined seek into another item silently drops its offset.
/// - [seek] into another item moves to the item first, waits until it is ready, then seeks the
///   offset, for the same reason.
///
/// The spike's third finding, position resetting to zero on completion, is the coordinator's to
/// ignore; this adapter reports what the player reports.
///
/// Running the app found two more, both about what happens after the queue completes:
///
/// - just_audio leaves `playing` true after completion and ignores `play()` while it is true, so
///   the next play would do nothing. This adapter pauses on completion, as just_audio's own
///   documentation advises.
/// - The Windows backend stays in its completed state through later seeks, so it would neither
///   start again cleanly nor report a second completion. After completion, [seek] reloads the queue
///   at the destination instead, which resets it by way of the load path spike (b) measured as
///   exact.
///
/// A whole file plays as itself. Only a stretch cut out of a file is wrapped in a clipping source.
/// The spike measured plain playback on Windows but not the backend's clipping, so the common case
/// stays on the path that was measured.
final class JustAudioEngine implements PlaybackEngine {
  JustAudioEngine() {
    _subscriptions
      ..add(_player.positionStream.listen(_onPosition))
      ..add(_player.currentIndexStream.listen(_onIndex))
      ..add(_player.processingStateStream.listen(_onProcessingState))
      ..add(_player.playbackEventStream.listen((_) {}, onError: _onError));
  }

  /// Run once, before the first engine is created. Enables the mpv backend on the platforms where
  /// `just_audio` has no native player of its own, which includes Windows.
  static void initialize() => JustAudioMediaKit.ensureInitialized();

  /// How long a seek into another item may wait for that item to become ready.
  static const _itemReadyTimeout = Duration(seconds: 10);

  final _player = ja.AudioPlayer();
  final _events = StreamController<EngineEvent>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _buffering = false;

  /// What was last loaded, to reload after completion.
  List<EngineItem> _items = const [];

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Future<void> load(
    List<EngineItem> items, {
    QueuePosition startAt = const QueuePosition(itemIndex: 0, offsetMs: 0),
  }) async {
    _items = List.unmodifiable(items);
    await _player.setAudioSources(
      [for (final item in items) _source(item)],
      initialIndex: startAt.itemIndex,
      initialPosition: Duration(milliseconds: startAt.offsetMs),
    );
  }

  @override
  Future<void> play() async {
    // Deliberately not awaited: just_audio's play() completes when playback stops, not when it
    // starts. Spike (b) lost a debugging cycle to exactly this.
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(QueuePosition position) async {
    if (_player.processingState == ja.ProcessingState.completed) {
      await load(_items, startAt: position);
      return;
    }
    if (_player.currentIndex != position.itemIndex) {
      await _player.seek(Duration.zero, index: position.itemIndex);
      await _player.currentIndexStream
          .firstWhere((index) => index == position.itemIndex)
          .timeout(_itemReadyTimeout);
      await _player.processingStateStream
          .firstWhere(
            (state) =>
                state == ja.ProcessingState.ready ||
                state == ja.ProcessingState.completed,
          )
          .timeout(_itemReadyTimeout);
    }
    await _player.seek(Duration(milliseconds: position.offsetMs));
  }

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _events.close();
    await _player.dispose();
  }

  ja.AudioSource _source(EngineItem entry) {
    final media = entry.media;
    final source = ja.AudioSource.uri(
      media.uri,
      headers: media.headers.isEmpty ? null : media.headers,
    );
    final item = entry.item;
    if (item.startsAtFileStart && item.endsAtFileEnd) return source;
    return ja.ClippingAudioSource(
      child: source,
      start: Duration(milliseconds: item.clipStartMs),
      end: item.endsAtFileEnd ? null : Duration(milliseconds: item.clipEndMs),
    );
  }

  void _onPosition(Duration position) {
    final index = _player.currentIndex;
    if (index == null) return;
    _events.add(
      EnginePositionChanged(
        QueuePosition(itemIndex: index, offsetMs: position.inMilliseconds),
      ),
    );
  }

  void _onIndex(int? index) {
    if (index != null) _events.add(EngineItemChanged(index));
  }

  void _onProcessingState(ja.ProcessingState state) {
    switch (state) {
      case ja.ProcessingState.loading || ja.ProcessingState.buffering:
        _setBuffering(true);
      case ja.ProcessingState.ready:
        _setBuffering(false);
      case ja.ProcessingState.completed:
        _setBuffering(false);
        unawaited(_player.pause());
        _events.add(const EngineCompleted());
      case ja.ProcessingState.idle:
        break;
    }
  }

  void _setBuffering(bool buffering) {
    if (buffering == _buffering) return;
    _buffering = buffering;
    _events.add(EngineBufferingChanged(buffering: buffering));
  }

  void _onError(Object error, StackTrace stackTrace) =>
      _events.add(EngineFailed(error));
}
