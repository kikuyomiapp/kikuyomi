/// How fast downloads are actually moving (§5.2).
///
/// Deliberately not in the database. A progress report arrives every few hundred milliseconds, and
/// writing a speed to the row each time would churn a table that every open screen is watching, for a
/// number that is worthless a second later. Speed is the one thing about a download that is not worth
/// surviving a restart: it is a property of the last few seconds, not of the task.
///
/// So it lives here, in memory, fed by the same reports the driver already receives, and a screen that
/// wants it asks and redraws on a timer of its own.
library;

/// The moving speed of each download, from the progress reports as they arrive.
final class DownloadRates {
  DownloadRates({this.window = const Duration(seconds: 5)});

  /// How far back a speed is measured over.
  ///
  /// Long enough that a stalled packet does not read as "0 B/s" and a burst does not read as 90 MB/s,
  /// short enough that throttling or a lost connection shows up while the listener is still looking.
  /// Five seconds is about where a progress readout stops twitching and starts being useful.
  final Duration window;

  final _samples = <int, List<_Sample>>{};

  /// Records that [taskId] had [bytesDone] at [at].
  void sample(int taskId, {required int bytesDone, required DateTime at}) {
    final samples = _samples.putIfAbsent(taskId, () => []);
    // Bytes going backwards means this is not the same fetch any more — a task restarted, or one that
    // reported nought because the site had not said how big the file was. Whatever came before
    // describes a different download and would give a negative speed.
    if (samples.isNotEmpty && bytesDone < samples.last.bytesDone) {
      samples.clear();
    }
    samples.add(_Sample(at: at, bytesDone: bytesDone));
    final oldest = at.subtract(window);
    // One sample from before the window is kept, because it is the far end of the measurement: drop
    // it and a steady download measured over exactly the window would have nothing to compare to.
    while (samples.length > 2 && samples[1].at.isBefore(oldest)) {
      samples.removeAt(0);
    }
  }

  /// How fast [taskId] is moving at [now], in bytes per second, or null when it cannot be said.
  ///
  /// Null rather than nought for "not known yet" and for "has not reported lately", because a screen
  /// showing 0 B/s on a download that is working is worse than a screen showing nothing.
  double? bytesPerSecond(int taskId, DateTime now) {
    final samples = _samples[taskId];
    if (samples == null || samples.length < 2) return null;
    // Nothing since the window closed: the task is paused, finished, or wedged, and the last speed it
    // was moving at is no longer true.
    if (now.difference(samples.last.at) > window) return null;
    final first = samples.first;
    final last = samples.last;
    final elapsed = last.at.difference(first.at);
    // Two reports in the same instant say nothing about speed, and dividing by their difference says
    // something absurd.
    if (elapsed < const Duration(milliseconds: 250)) return null;
    final moved = last.bytesDone - first.bytesDone;
    if (moved <= 0) return 0;
    return moved * 1000 / elapsed.inMilliseconds;
  }

  /// What [taskIds] are moving at together, or null when none of them can say.
  ///
  /// The figure a book shows: its files download two at a time, and the listener is waiting on the
  /// book rather than on either file.
  double? totalBytesPerSecond(Iterable<int> taskIds, DateTime now) {
    double? total;
    for (final taskId in taskIds) {
      final rate = bytesPerSecond(taskId, now);
      if (rate != null) total = (total ?? 0) + rate;
    }
    return total;
  }

  /// Every task that can say how fast it is moving at [now], by task id.
  ///
  /// What a screen asks for once a second: one call rather than a lookup per row, and it leaves out
  /// the tasks with nothing to say so a caller can treat a missing entry as "no speed to show".
  Map<int, double> snapshot(DateTime now) => {
    for (final taskId in _samples.keys)
      if (bytesPerSecond(taskId, now) case final rate?) taskId: rate,
  };

  /// Forgets [taskId], once it has stopped or finished.
  void forget(int taskId) => _samples.remove(taskId);

  /// Forgets everything. For a driver being disposed.
  void clear() => _samples.clear();
}

final class _Sample {
  const _Sample({required this.at, required this.bytesDone});

  final DateTime at;
  final int bytesDone;
}
