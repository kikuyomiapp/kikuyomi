import 'dart:async';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'coordinator.dart';
import 'player_state.dart';

/// What the system's media controls show for the open book (§6.5): the lock screen and
/// notification, Bluetooth devices and watches on phones, and the media flyout on Windows.
final class MediaSessionState {
  const MediaSessionState({
    required this.title,
    required this.album,
    this.artist,
    required this.durationMs,
    required this.positionMs,
    required this.updatedAt,
    required this.playing,
    required this.buffering,
    required this.speed,
  });

  /// The chapter, the line that changes as the book plays.
  final String title;

  /// The book.
  final String album;

  /// The book's first author, if it has one.
  final String? artist;

  /// The whole book, since the controls' scrubber seeks in book-global time.
  final int durationMs;
  final int positionMs;

  /// When [positionMs] was true. Controls extrapolate from here while playing, so they need no
  /// update for every tick of the position.
  final DateTime updatedAt;
  final bool playing;
  final bool buffering;
  final double speed;

  /// Where the controls take playback to be at [time], extrapolated from [positionMs].
  int positionAt(DateTime time) => playing && !buffering
      ? positionMs + (time.difference(updatedAt).inMilliseconds * speed).round()
      : positionMs;
}

/// A button pressed in the system's media controls.
sealed class MediaCommand {
  const MediaCommand();
}

final class MediaPlay extends MediaCommand {
  const MediaPlay();
}

final class MediaPause extends MediaCommand {
  const MediaPause();
}

/// A single button that toggles, such as a headset's.
final class MediaPlayPause extends MediaCommand {
  const MediaPlayPause();
}

final class MediaSkipForward extends MediaCommand {
  const MediaSkipForward();
}

final class MediaSkipBackward extends MediaCommand {
  const MediaSkipBackward();
}

/// A seek from the controls' scrubber, in book-global time.
final class MediaSeek extends MediaCommand {
  const MediaSeek(this.positionMs);

  final int positionMs;
}

final class MediaNextChapter extends MediaCommand {
  const MediaNextChapter();
}

final class MediaPreviousChapter extends MediaCommand {
  const MediaPreviousChapter();
}

/// §6.1's `MediaSessionBridge`: the platform's media controls. `audio_service` on Android and iOS,
/// and SMTC on Windows.
abstract interface class MediaSessionBridge {
  /// Shows [state], or removes the controls when it is null.
  void update(MediaSessionState? state);

  /// The buttons pressed.
  Stream<MediaCommand> get commands;
}

/// How a book is named in the media controls.
final class BookDescription {
  const BookDescription({required this.title, this.author});

  final String title;
  final String? author;
}

/// Keeps a [MediaSessionBridge] in step with a [PlaybackCoordinator], and passes its buttons back.
///
/// It republishes only when something the controls show has changed, or when the position has
/// moved away from where the controls would have extrapolated it, as after a seek. The coordinator
/// publishes a new state for every position sample, several a second, and pushing each one to an
/// Android notification would cost battery for nothing.
final class MediaSessionSync {
  MediaSessionSync({
    required PlaybackCoordinator coordinator,
    required MediaSessionBridge bridge,
    required Future<BookDescription> Function(int bookId) describe,
    required Clock clock,
    this.skipInterval = const Duration(seconds: 30),
  }) : _coordinator = coordinator,
       _bridge = bridge,
       _describe = describe,
       _clock = clock;

  /// How far the skip buttons move.
  final Duration skipInterval;

  /// How far the position may stray from the controls' extrapolation before they are corrected.
  static const _driftToleranceMs = 1000;

  final PlaybackCoordinator _coordinator;
  final MediaSessionBridge _bridge;
  final Future<BookDescription> Function(int bookId) _describe;
  final Clock _clock;

  final _descriptions = <int, BookDescription>{};
  final _describing = <int>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  PlayerState _latest = const PlayerIdle();
  MediaSessionState? _shown;

  /// Starts following the coordinator and listening to the controls.
  void start() {
    _subscriptions
      ..add(_coordinator.states.listen(_onState))
      ..add(
        _bridge.commands.listen((command) => unawaited(_onCommand(command))),
      );
    _onState(_coordinator.state);
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }

  void _onState(PlayerState state) {
    _latest = state;
    _publish();
  }

  void _publish() {
    switch (_latest) {
      case final PlayerReady ready:
        final description = _descriptions[ready.bookId];
        if (description == null) {
          _lookUp(ready.bookId);
          return;
        }
        final next = MediaSessionState(
          title: ready.entry.title,
          album: description.title,
          artist: description.author,
          durationMs: ready.totalMs,
          positionMs: ready.globalMs,
          updatedAt: _clock.now(),
          playing: ready.playing,
          buffering: ready.buffering,
          speed: ready.speed,
        );
        if (_worthShowing(next)) {
          _shown = next;
          _bridge.update(next);
        }
      case PlayerIdle() || PlayerFailed():
        if (_shown != null) {
          _shown = null;
          _bridge.update(null);
        }
      case PlayerLoading():
        break;
    }
  }

  bool _worthShowing(MediaSessionState next) {
    final shown = _shown;
    if (shown == null ||
        next.title != shown.title ||
        next.album != shown.album ||
        next.artist != shown.artist ||
        next.durationMs != shown.durationMs ||
        next.playing != shown.playing ||
        next.buffering != shown.buffering ||
        next.speed != shown.speed) {
      return true;
    }
    final drift = next.positionMs - shown.positionAt(next.updatedAt);
    return drift.abs() > _driftToleranceMs;
  }

  void _lookUp(int bookId) {
    if (!_describing.add(bookId)) return;
    unawaited(
      _describe(bookId).then(
        (description) {
          _descriptions[bookId] = description;
          _publish();
        },
        onError: (Object _) {
          // A book whose details cannot be read still gets controls, named by its chapter alone.
          _descriptions[bookId] = const BookDescription(title: '');
          _publish();
        },
      ),
    );
  }

  Future<void> _onCommand(MediaCommand command) => switch (command) {
    MediaPlay() => _coordinator.play(),
    MediaPause() => _coordinator.pause(),
    MediaPlayPause() => switch (_latest) {
      PlayerReady(playing: true) => _coordinator.pause(),
      _ => _coordinator.play(),
    },
    MediaSkipForward() => _coordinator.skip(skipInterval),
    MediaSkipBackward() => _coordinator.skip(-skipInterval),
    MediaSeek(:final positionMs) => _coordinator.seekTo(positionMs),
    MediaNextChapter() => _coordinator.nextChapter(),
    MediaPreviousChapter() => _coordinator.previousChapter(),
  };
}
