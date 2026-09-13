import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// Decides when progress is written and what gets written.
///
/// It never writes anything itself. Each method returns the position to persist, or null when
/// nothing should be written, and the coordinator does the writing. That keeps every rule here
/// testable without a database.
///
/// The rules, from §6.4 and spike (b):
///
/// - During playback, at most one write per [throttle].
/// - Immediately on pause, seek, chapter change, interruption, and moving to the background.
/// - Never the same position twice in a row.
/// - **Never a position reported after the engine completed.** Spike (b) measured the Windows
///   backend resetting position to zero on completion; the obvious implementation, which saves
///   whatever the position stream reports, would record every finished chapter as unstarted.
final class ProgressTracker {
  ProgressTracker({
    required Timeline timeline,
    required Clock clock,
    this.throttle = const Duration(seconds: 5),
  }) : _timeline = timeline,
       _clock = clock;

  final Duration throttle;
  final Clock _clock;
  Timeline _timeline;

  ChapterPosition? _lastObserved;
  ChapterPosition? _lastWritten;
  DateTime? _lastWriteAt;
  bool _completed = false;

  /// The most recent real position, whether or not it has been written yet.
  ChapterPosition? get lastObserved => _lastObserved;

  /// Swaps in a Timeline rebuilt after a duration was refined.
  ///
  /// Tracked positions are chapter-relative, so they stay correct across the swap; only how future
  /// engine positions are interpreted changes.
  void updateTimeline(Timeline timeline) => _timeline = timeline;

  /// A queue has been loaded at [startAt]. Nothing is written: loading is not listening.
  void onLoaded(QueuePosition startAt) {
    _completed = false;
    _lastObserved = _timeline.chapterPositionOfQueue(startAt);
    _lastWriteAt = null;
  }

  /// A position sample from the engine during playback.
  ChapterPosition? onPosition(QueuePosition position) {
    if (_completed) return null;
    final current = _timeline.chapterPositionOfQueue(position);
    final previous = _lastObserved;
    _lastObserved = current;

    if (previous != null && previous.chapterId != current.chapterId) {
      return _write(current);
    }
    final lastWriteAt = _lastWriteAt;
    if (lastWriteAt == null ||
        _clock.now().difference(lastWriteAt) >= throttle) {
      return _write(current);
    }
    return null;
  }

  /// A seek the user asked for, written immediately at its destination.
  ChapterPosition? onSeek(QueuePosition destination) {
    _completed = false;
    final target = _timeline.chapterPositionOfQueue(destination);
    _lastObserved = target;
    return _write(target);
  }

  ChapterPosition? onPause() => _flush();

  ChapterPosition? onInterruption() => _flush();

  ChapterPosition? onBackgrounded() => _flush();

  /// The engine played the whole queue to its end.
  ///
  /// Writes the end of the book rather than the last sample. The Windows backend stops a few
  /// hundred milliseconds short of nominal duration, by a margin that varied between runs in spike
  /// (b), so the last sample is noise; completion is the authoritative signal. Everything the
  /// engine reports afterwards is ignored until the next load or seek.
  ChapterPosition? onCompleted() {
    if (_completed) return null;
    _completed = true;
    final end = _timeline.chapterPositionAt(_timeline.totalDurationMs);
    _lastObserved = end;
    return _write(end);
  }

  ChapterPosition? _flush() {
    final position = _lastObserved;
    return position == null ? null : _write(position);
  }

  ChapterPosition? _write(ChapterPosition position) {
    if (position == _lastWritten) return null;
    _lastWritten = position;
    _lastWriteAt = _clock.now();
    return position;
  }
}
