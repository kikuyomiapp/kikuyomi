import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// What the playback engine reports.
///
/// §6.1: the engine knows nothing about books or chapters. Everything here is in queue
/// coordinates, and turning that into progress is the Timeline's job.
sealed class EngineEvent {
  const EngineEvent();
}

/// A position sample while an item is loaded.
///
/// A sample received after [EngineCompleted] is not a position. Spike (b) measured the just_audio
/// Windows backend resetting position to zero on completion, so consumers must not persist it.
final class EnginePositionChanged extends EngineEvent {
  const EnginePositionChanged(this.position);

  final QueuePosition position;
}

/// The engine moved to another queue item on its own, at a file boundary.
final class EngineItemChanged extends EngineEvent {
  const EngineItemChanged(this.itemIndex);

  final int itemIndex;
}

/// The engine started or stopped waiting for data.
final class EngineBufferingChanged extends EngineEvent {
  const EngineBufferingChanged({required this.buffering});

  final bool buffering;
}

/// The whole queue played to its end.
final class EngineCompleted extends EngineEvent {
  const EngineCompleted();
}

/// Playback failed. §6.3: a stream error triggers one transparent re-resolve before the user sees
/// anything, so this is an input to that retry, not necessarily a user-facing error.
final class EngineFailed extends EngineEvent {
  const EngineFailed(this.error);

  final Object error;
}

/// The audio engine, as §6.1 specifies it: load a list of file items, play, pause, seek to an
/// offset in an item, set speed, and emit events.
///
/// Implementations must honour two contracts that spike (b) found the just_audio backend on
/// Windows does not honour on its own. ADR-0006 records both, and they are stated on [load] and
/// [seek] so that an implementer cannot miss them.
abstract interface class PlaybackEngine {
  /// Loads [items] and positions the engine at [startAt] before playback begins.
  ///
  /// The start position is part of loading deliberately. On just_audio's Windows backend a
  /// combined seek to a position in a different item silently discards the position and lands at
  /// the start of the item, whereas loading with an initial index and initial position is exact.
  /// Resuming a book is the single most important thing the engine does, so it takes the path
  /// that was measured to work.
  Future<void> load(
    List<QueueItem> items, {
    QueuePosition startAt = const QueuePosition(itemIndex: 0, offsetMs: 0),
  });

  Future<void> play();

  Future<void> pause();

  /// Moves to [position], which may be in a different item, and must land on both the item and the
  /// offset.
  ///
  /// An implementation over just_audio must move to the item first and then seek to the offset as
  /// a separate step, for the reason given on [load].
  Future<void> seek(QueuePosition position);

  /// §6.5: 0.5x to 3.5x, pitch preserved.
  Future<void> setSpeed(double speed);

  Stream<EngineEvent> get events;

  Future<void> dispose();
}
