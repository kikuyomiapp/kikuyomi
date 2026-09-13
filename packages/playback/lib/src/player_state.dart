import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'sleep_timer.dart';

/// The one state every piece of player UI watches (§6.1).
sealed class PlayerState {
  const PlayerState();
}

/// No book is open.
final class PlayerIdle extends PlayerState {
  const PlayerIdle();
}

/// A book is being opened: its files are resolving and loading.
final class PlayerLoading extends PlayerState {
  const PlayerLoading(this.bookId);

  final int bookId;
}

/// A book is open.
final class PlayerReady extends PlayerState {
  const PlayerReady({
    required this.bookId,
    required this.position,
    required this.globalMs,
    required this.totalMs,
    required this.entry,
    required this.playing,
    required this.buffering,
    required this.speed,
    required this.sleepTimer,
    required this.finished,
  });

  final int bookId;

  /// Where playback is, in the chapter-relative form progress is stored in.
  final ChapterPosition position;

  /// The same position in book-global time, for the scrubber.
  final int globalMs;
  final int totalMs;

  /// The chapter, or embedded marker presented as one, that playback is in.
  final NavigationEntry entry;
  final bool playing;
  final bool buffering;
  final double speed;
  final SleepTimerState sleepTimer;

  /// True once the book has played to its end.
  final bool finished;

  int get remainingMs => totalMs - globalMs;
}

/// Playback failed and automatic recovery did not help.
final class PlayerFailed extends PlayerState {
  const PlayerFailed({required this.bookId, required this.error});

  final int bookId;
  final Object error;
}
