import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';

import 'cached_audio_source.dart';
import 'stream_audio_cache.dart';

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
///
/// Each item's duration is reported once the player knows it (§4.5), from a ready player only; see
/// [_reportDuration] for why.
final class JustAudioEngine implements PlaybackEngine {
  JustAudioEngine({this.cache, this.userAgent, this.onStreamFailure}) {
    _subscriptions
      ..add(_player.positionStream.listen(_onPosition))
      ..add(_player.currentIndexStream.listen(_onIndex))
      ..add(_player.processingStateStream.listen(_onProcessingState))
      ..add(
        _player.playbackEventStream.listen(_onPlaybackEvent, onError: _onError),
      );
  }

  /// Run once, before the first engine is created. Enables the mpv backend on the platforms where
  /// `just_audio` has no native player of its own, which includes Windows.
  static void initialize() => JustAudioMediaKit.ensureInitialized();

  /// Where a streamed file's bytes are kept, or null to fetch them again every time.
  ///
  /// Only a file that comes over the network goes through it. A local book's files are played
  /// straight from where they are, exactly as before: copying them into a cache would be copying
  /// the device's own storage onto itself.
  final StreamAudioCache? cache;

  /// How the app names itself when it fetches a stream's bytes itself, which it does for every file
  /// it caches. §2.7 decides it in one place; this is where that reaches the audio.
  final String? userAgent;

  /// Told when a streamed file cannot be resolved or fetched, with the address it was fetching from.
  ///
  /// The bytes of a cached stream are fetched here and served to the player through a local proxy,
  /// so a failure reaches the player as its own platform's word for "the proxy gave me nothing" and
  /// the status the site really answered with is lost. This carries it to somewhere it can be read.
  final void Function(Object error, Uri? uri)? onStreamFailure;

  /// How long a seek into another item may wait for that item to become ready.
  static const _itemReadyTimeout = Duration(seconds: 10);

  /// Interruptions and unplugged headphones are the coordinator's to handle (§6.5), and reach it
  /// through `AudioFocus`. Left to just_audio, they would pause the player behind the
  /// coordinator's back, and the coordinator would go on believing the book was playing.
  final _player = ja.AudioPlayer(handleInterruptions: false);
  final _events = StreamController<EngineEvent>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _buffering = false;

  /// What was last loaded, to reload after completion.
  List<EngineItem> _items = const [];

  /// The duration last reported for each item of the loaded queue, so that each is reported once
  /// rather than with every playback event.
  final _reportedDurations = <int, Duration>{};

  /// True while a queue is loading, when a playback event may still describe the previous queue.
  bool _loading = false;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Future<void> load(
    List<EngineItem> items, {
    QueuePosition startAt = const QueuePosition(itemIndex: 0, offsetMs: 0),
  }) async {
    _items = List.unmodifiable(items);
    _reportedDurations.clear();
    _loading = true;
    try {
      final sources = [for (final item in items) await _source(item)];
      await _player.setAudioSources(
        sources,
        initialIndex: startAt.itemIndex,
        initialPosition: Duration(milliseconds: startAt.offsetMs),
      );
    } catch (_) {
      // A load that failed leaves the player holding a source it could not open, and the backends do
      // not agree on what happens next: AVFoundation reports the same failure again for the following
      // load, and the Windows backend accepts it and plays nothing. Either way one unopenable book
      // would cost the listener every other book in the library, local files included, until the app
      // was restarted — which is what this catch exists to prevent. The queue is emptied and the
      // player stopped, so the next load starts from an idle player, and the failure is passed on for
      // the coordinator to report.
      _items = const [];
      _reportedDurations.clear();
      try {
        await _player.stop();
      } catch (_) {
        // A player that cannot even be stopped has nothing left to reset.
      }
      rethrow;
    } finally {
      _loading = false;
    }
    // A duration learned while loading arrived when events were being ignored.
    _reportDuration(_player.playbackEvent);
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

  /// What the player is given for one queue item.
  ///
  /// A whole file fetched over the network goes through [CachedAudioSource]: it is resolved when
  /// the player first asks for its bytes, and what it fetches is kept. A file on the device is
  /// played where it is. Either way a stretch cut out of a file is wrapped in a clipping source,
  /// which `just_audio` builds only over a plain URL, so a clipped item is resolved here and
  /// fetched again each time it is played. No source seen so far cuts a chapter out of a streamed
  /// file; the ones that do are the M4B and folder books already on the device, which need no
  /// cache.
  Future<ja.AudioSource> _source(EngineItem entry) async {
    final item = entry.item;
    final whole = item.startsAtFileStart && item.endsAtFileEnd;
    final known = entry.media;
    final store = cache;
    if (whole && store != null && (known == null || _isRemote(known.uri))) {
      return CachedAudioSource(
        fileId: item.fileId,
        cache: store,
        resolve: () async => known ?? await entry.resolve(),
        userAgent: userAgent,
        onFailure: onStreamFailure,
      );
    }
    final media = known ?? await entry.resolve();
    final source = ja.AudioSource.uri(
      media.uri,
      headers: media.headers.isEmpty ? null : media.headers,
    );
    if (whole) return source;
    return ja.ClippingAudioSource(
      child: source,
      start: Duration(milliseconds: item.clipStartMs),
      end: item.endsAtFileEnd ? null : Duration(milliseconds: item.clipEndMs),
    );
  }

  static bool _isRemote(Uri uri) =>
      uri.scheme == 'http' || uri.scheme == 'https';

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

  void _onPlaybackEvent(ja.PlaybackEvent event) {
    if (!_loading) _reportDuration(event);
  }

  /// Reports how long the current item is, once the player has settled on a figure for it.
  ///
  /// Each playback event carries the current item's duration, but not every figure can be trusted:
  ///
  /// - Only a ready player's counts. When the Windows backend moves to another item, it fills the
  ///   still missing duration from mpv's last known one, which belongs to the previous file, so for
  ///   a moment the new item carries the old item's length. mpv reports the new file's length as it
  ///   opens the file, before playback is ready.
  /// - None counts while a queue is loading, when an event already on its way may still pair an
  ///   index in the previous queue with a length from it. The latest event is read once loading
  ///   finishes instead.
  /// - Zero is how the Windows backend says it does not know yet.
  ///
  /// The coordinator stores what this reports as exact, so a wrong figure would outlast the session.
  /// These rules come from reading `just_audio_media_kit` 2.1.0 and `media_kit` 1.2.6, not from a
  /// measurement: the stale length has not been observed on a device.
  void _reportDuration(ja.PlaybackEvent event) {
    final index = event.currentIndex;
    final duration = event.duration;
    if (event.processingState != ja.ProcessingState.ready ||
        index == null ||
        index >= _items.length ||
        duration == null ||
        duration <= Duration.zero ||
        _reportedDurations[index] == duration) {
      return;
    }
    _reportedDurations[index] = duration;
    _events.add(
      EngineItemDurationKnown(
        itemIndex: index,
        durationMs: duration.inMilliseconds,
      ),
    );
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
