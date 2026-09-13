import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// What the sleep timer is waiting for.
sealed class SleepTimerTarget {
  const SleepTimerTarget();
}

/// Stop after this much listening time.
final class SleepAfter extends SleepTimerTarget {
  const SleepAfter(this.duration);

  final Duration duration;
}

/// Stop when the current chapter ends.
final class SleepAtEndOfChapter extends SleepTimerTarget {
  const SleepAtEndOfChapter();
}

/// What the coordinator should do about the timer right now.
sealed class SleepTimerState {
  const SleepTimerState();
}

/// No timer is set.
final class SleepTimerOff extends SleepTimerState {
  const SleepTimerOff();
}

/// A timer is counting down.
final class SleepTimerRunning extends SleepTimerState {
  const SleepTimerRunning({required this.remaining, required this.volume});

  /// Listening time left before playback stops.
  final Duration remaining;

  /// 1.0 until the fade begins, then falling linearly to 0.0 as [remaining] runs out.
  final double volume;
}

/// The timer has run out: pause playback now and restore the volume.
final class SleepTimerExpired extends SleepTimerState {
  const SleepTimerExpired();
}

/// §6.5's sleep timer: presets or a custom duration, or "end of chapter"; a fade over the final 15 to
/// 30 seconds; and a small automatic rewind when playback resumes after the timer stopped it.
///
/// This decides; it does not act. The coordinator polls it and applies the volume and pause it
/// returns. That keeps it free of real timers, so it is testable against a fake clock, and §6.5's
/// note still holds: a periodic poll in the main isolate keeps working in the background because
/// active playback keeps the process alive on every platform.
///
/// Choices §6.5 leaves open:
///
/// - A duration timer counts **listening** time, so it stands still while playback is paused. A
///   timer that expired during a pause would stop nothing and simply vanish.
/// - "End of chapter" measures what is left in listening time, so at 2x speed a chapter with 40
///   seconds of audio left has 20 seconds of listening left, and the fade starts accordingly.
/// - The rewind after a timer stop is the fade length: that is the stretch the listener most likely
///   did not hear. It is independent of smart rewind; applying the larger of the two on resume is
///   the coordinator's call.
final class SleepTimer {
  /// Throws [ArgumentError] unless [fade] is within §6.5's 15 to 30 seconds.
  SleepTimer({required Clock clock, this.fade = const Duration(seconds: 20)})
    : _clock = clock {
    if (fade < const Duration(seconds: 15) ||
        fade > const Duration(seconds: 30)) {
      throw ArgumentError.value(
        fade,
        'fade',
        'must be between 15 and 30 seconds',
      );
    }
  }

  final Duration fade;
  final Clock _clock;

  SleepTimerTarget? _target;
  bool _playing = false;
  DateTime? _playingSince;
  Duration _banked = Duration.zero;
  Duration _pendingRewind = Duration.zero;

  bool get isActive => _target != null;

  /// Sets a timer, replacing any timer already set.
  void start(SleepTimerTarget target) {
    _target = target;
    _banked = Duration.zero;
    _playingSince = _playing ? _clock.now() : null;
  }

  void cancel() {
    _target = null;
    _banked = Duration.zero;
    _playingSince = null;
  }

  /// Adds time to a running duration timer, as shake-to-extend does on phones.
  ///
  /// Throws [StateError] when no duration timer is running: "end of chapter" has no length to add
  /// to. Throws [ArgumentError] for a negative [by].
  void extend(Duration by) {
    if (by.isNegative) {
      throw ArgumentError.value(
        by,
        'by',
        'cannot extend by a negative duration',
      );
    }
    final target = _target;
    if (target is! SleepAfter) {
      throw StateError('only a running duration timer can be extended');
    }
    _target = SleepAfter(target.duration + by);
  }

  /// Playback started or resumed.
  void onPlaying() {
    if (_playing) return;
    _playing = true;
    _playingSince = _clock.now();
  }

  /// Playback paused, for any reason.
  void onPaused() {
    if (!_playing) return;
    _banked = _listened();
    _playing = false;
    _playingSince = null;
  }

  /// Evaluates the timer.
  ///
  /// [chapterRemaining] is the audio left in the current chapter and is required for an
  /// end-of-chapter timer. [speed] converts audio time into listening time.
  ///
  /// Returns [SleepTimerExpired] exactly once when the timer runs out, after which the timer is off.
  SleepTimerState poll({Duration? chapterRemaining, double speed = 1.0}) {
    final target = _target;
    if (target == null) return const SleepTimerOff();
    if (speed <= 0) {
      throw ArgumentError.value(speed, 'speed', 'must be positive');
    }

    final remaining = switch (target) {
      SleepAfter(:final duration) => duration - _listened(),
      SleepAtEndOfChapter() => Duration(
        microseconds:
            ((chapterRemaining ??
                            (throw ArgumentError.notNull('chapterRemaining')))
                        .inMicroseconds /
                    speed)
                .round(),
      ),
    };

    if (remaining <= Duration.zero) {
      cancel();
      _pendingRewind = fade;
      return const SleepTimerExpired();
    }
    final volume = remaining >= fade
        ? 1.0
        : remaining.inMicroseconds / fade.inMicroseconds;
    return SleepTimerRunning(remaining: remaining, volume: volume);
  }

  /// The rewind to apply when playback next resumes.
  ///
  /// Returns [fade] once after the timer stopped playback, and zero otherwise, including after a
  /// timer was cancelled before it ran out.
  Duration takeResumeRewind() {
    final rewind = _pendingRewind;
    _pendingRewind = Duration.zero;
    return rewind;
  }

  Duration _listened() {
    final since = _playingSince;
    if (since == null) return _banked;
    final span = _clock.now().difference(since);
    // A clock set backwards must not give listening time back.
    return span.isNegative ? _banked : _banked + span;
  }
}
