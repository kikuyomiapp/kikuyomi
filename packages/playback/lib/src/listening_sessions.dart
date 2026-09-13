import 'dart:math' as math;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// One continuous stretch of listening, as §4.3's `listening_session` row records it.
///
/// The device id is not here; it belongs to the app, and the coordinator attaches it when writing.
final class ListeningSession {
  const ListeningSession({
    required this.bookId,
    required this.chapterId,
    required this.startedAt,
    required this.endedAt,
    required this.startGlobalMs,
    required this.endGlobalMs,
    required this.speed,
  });

  final int bookId;
  final int chapterId;
  final DateTime startedAt;
  final DateTime endedAt;
  final int startGlobalMs;
  final int endGlobalMs;
  final double speed;

  /// Wall-clock time spent listening, which is what "time listened" statistics add up.
  Duration get listened => endedAt.difference(startedAt);

  /// How much of the book this stretch covered. At 2x speed this is about twice [listened].
  int get coveredMs => endGlobalMs - startGlobalMs;
}

/// Turns playback into listening sessions, per §6.4: each play-to-pause span becomes a
/// `listening_session` for history and statistics.
///
/// Like the progress tracker, it returns what to persist and writes nothing.
///
/// A play-to-pause span does not map onto one row as cleanly as §6.4 suggests, because a row has a
/// single chapter, a single speed, and one start and end position. So a span is **split**, ending
/// one session and starting the next at the same instant, whenever:
///
/// - playback crosses into another chapter, so history can say which chapter was listened to;
/// - the speed changes, so each row's speed is true for its whole length;
/// - the user seeks, so each row's start and end positions describe a stretch actually heard,
///   rather than bracketing a jump.
///
/// Splitting never changes the total time listened; it only makes each row honest.
///
/// Sessions shorter than [minimumLength] are dropped. Scrubbing back and forth while playing
/// produces a burst of splits a second or two long each, and those would bury real history without
/// adding meaningful time to any statistic. A clock set backwards produces a negative length and is
/// dropped for the same reason.
final class ListeningSessionRecorder {
  /// Throws [ArgumentError] for a negative [minimumLength].
  ListeningSessionRecorder({
    required this.bookId,
    required Timeline timeline,
    required Clock clock,
    this.minimumLength = const Duration(seconds: 5),
  }) : _timeline = timeline,
       _clock = clock {
    if (minimumLength.isNegative) {
      throw ArgumentError.value(
        minimumLength,
        'minimumLength',
        'cannot be negative',
      );
    }
  }

  final int bookId;
  final Duration minimumLength;
  final Clock _clock;
  Timeline _timeline;

  _OpenSession? _open;

  bool get isRecording => _open != null;

  /// Swaps in a Timeline rebuilt after a duration was refined.
  void updateTimeline(Timeline timeline) => _timeline = timeline;

  /// Playback started at [globalMs]. Ignored if a session is already open.
  void onPlay({required int globalMs, required double speed}) {
    if (_open != null) return;
    _open = _OpenSession(
      chapterId: _chapterAt(globalMs),
      startedAt: _clock.now(),
      startGlobalMs: globalMs,
      speed: speed,
    );
  }

  /// A position sample during playback. Splits the session when it has crossed into a new chapter.
  ListeningSession? onPosition(int globalMs) {
    final open = _open;
    if (open == null) return null;
    final chapterId = _chapterAt(globalMs);
    if (chapterId == open.chapterId) return null;
    final boundary = _timeline.chapterRange(chapterId).startMs;
    return _split(
      endGlobalMs: boundary,
      nextStartGlobalMs: boundary,
      nextChapterId: chapterId,
      nextSpeed: open.speed,
    );
  }

  /// The speed changed during playback.
  ListeningSession? onSpeedChanged({
    required int globalMs,
    required double speed,
  }) {
    final open = _open;
    if (open == null || speed == open.speed) return null;
    return _split(
      endGlobalMs: globalMs,
      nextStartGlobalMs: globalMs,
      nextChapterId: open.chapterId,
      nextSpeed: speed,
    );
  }

  /// The user sought from [fromGlobalMs] to [toGlobalMs] during playback.
  ListeningSession? onSeek({
    required int fromGlobalMs,
    required int toGlobalMs,
  }) {
    final open = _open;
    if (open == null) return null;
    return _split(
      endGlobalMs: fromGlobalMs,
      nextStartGlobalMs: toGlobalMs,
      nextChapterId: _chapterAt(toGlobalMs),
      nextSpeed: open.speed,
    );
  }

  /// Playback stopped at [globalMs], whatever stopped it: a pause, an interruption, completion, or
  /// the sleep timer.
  ListeningSession? onStop(int globalMs) {
    final open = _open;
    if (open == null) return null;
    _open = null;
    return _close(open, globalMs, _clock.now());
  }

  ListeningSession? _split({
    required int endGlobalMs,
    required int nextStartGlobalMs,
    required int nextChapterId,
    required double nextSpeed,
  }) {
    final open = _open!;
    final now = _clock.now();
    _open = _OpenSession(
      chapterId: nextChapterId,
      startedAt: now,
      startGlobalMs: nextStartGlobalMs,
      speed: nextSpeed,
    );
    return _close(open, endGlobalMs, now);
  }

  ListeningSession? _close(
    _OpenSession open,
    int endGlobalMs,
    DateTime endedAt,
  ) {
    if (endedAt.difference(open.startedAt) < minimumLength) return null;
    return ListeningSession(
      bookId: bookId,
      chapterId: open.chapterId,
      startedAt: open.startedAt,
      endedAt: endedAt,
      startGlobalMs: open.startGlobalMs,
      endGlobalMs: math.max(endGlobalMs, open.startGlobalMs),
      speed: open.speed,
    );
  }

  int _chapterAt(int globalMs) =>
      _timeline.chapterPositionAt(globalMs).chapterId;
}

final class _OpenSession {
  const _OpenSession({
    required this.chapterId,
    required this.startedAt,
    required this.startGlobalMs,
    required this.speed,
  });

  final int chapterId;
  final DateTime startedAt;
  final int startGlobalMs;
  final double speed;
}
