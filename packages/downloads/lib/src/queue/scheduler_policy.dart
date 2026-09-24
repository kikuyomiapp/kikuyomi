/// What the scheduler is allowed to start, and what it must hold back (§5.2).
///
/// This is the scheduler's judgement with nothing else attached: no transport, no database, no timer.
/// Given the tasks that could start, the limits in force and the state of the device, it says which
/// ones to begin and why each of the others is waiting. Everything that makes downloading hard to
/// reason about — three caps interacting, a metered connection, a disk filling up — is decided here,
/// where a test can put the world in any state in one line.
///
/// The rules come straight from §5.2: "a global concurrency cap (default 3), a per-source cap
/// (default 1 to 2, which extensions may lower), the user's network policy (Wi-Fi only or cellular
/// allowed on Android, respecting metered connections), and a free-space floor below which
/// downloading stops."
library;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// The caps and policies in force.
final class DownloadLimits {
  const DownloadLimits({
    this.atOnce = 3,
    this.perSource = 2,
    this.unmeteredOnly = true,
    this.freeSpaceFloorBytes = 500 * 1024 * 1024,
  });

  /// §5.2's global cap. Three is enough to keep a connection busy without turning a book into a
  /// denial-of-service against a volunteer-run site.
  final int atOnce;

  /// How many files may be fetched from one source at once. §5.2 allows an extension to lower this;
  /// nothing raises it.
  final int perSource;

  /// Whether downloading waits for an unmetered connection. The listener's setting, defaulting to
  /// the careful answer: an audiobook is hundreds of megabytes, and finding that out from a phone
  /// bill is the worst way to learn it.
  final bool unmeteredOnly;

  /// The free space the scheduler will not cross (§5.6). Checked before each file starts, against
  /// what that file is expected to need.
  final int freeSpaceFloorBytes;
}

/// What the device can offer right now.
final class DownloadConditions {
  const DownloadConditions({
    required this.network,
    required this.freeSpaceBytes,
    this.runningBySource = const {},
  });

  final NetworkKind network;

  /// What is left on the device where downloads go.
  final int freeSpaceBytes;

  /// How many files are already in flight, by source. Its total is the global count, so the two caps
  /// cannot disagree about what is running.
  final Map<int, int> runningBySource;

  /// How many files are in flight altogether.
  int get running =>
      runningBySource.values.fold(0, (total, count) => total + count);
}

/// What the scheduler decided about one task.
sealed class DownloadDecision {
  const DownloadDecision(this.taskId);

  final int taskId;
}

/// Begin this one.
final class StartDownload extends DownloadDecision {
  const StartDownload(super.taskId);

  @override
  String toString() => 'StartDownload($taskId)';
}

/// Leave this one where it is, for the named reason.
final class HoldDownload extends DownloadDecision {
  const HoldDownload(super.taskId, this.reason);

  final DownloadHold reason;

  @override
  String toString() => 'HoldDownload($taskId, ${reason.name})';
}

/// What to do with [candidates], most wanted first.
///
/// Every candidate gets a decision, so a caller can write down why each task is not moving without
/// working it out again. Order matters twice over: the list is sorted by priority and then by age, so
/// the most wanted tasks take the free slots, and a task that is started counts against the caps for
/// the ones after it in the same pass.
///
/// Two of the three holds are about the whole queue rather than one task. [DownloadHold.network] and
/// [DownloadHold.storage] stop everything, so when either applies no task is started at all — which
/// is deliberate: a disk that cannot hold the next file will not hold a smaller one either, and
/// starting the small ones would fill it the rest of the way.
List<DownloadDecision> chooseDownloads({
  required Iterable<DownloadCandidate> candidates,
  DownloadLimits limits = const DownloadLimits(),
  required DownloadConditions conditions,
}) {
  final ordered = [...candidates]..sort(_mostWantedFirst);

  final blocked = _wholeQueueHold(limits, conditions);
  if (blocked != null) {
    return [for (final task in ordered) HoldDownload(task.taskId, blocked)];
  }

  var running = conditions.running;
  final bySource = {...conditions.runningBySource};
  var freeSpace = conditions.freeSpaceBytes;

  final decisions = <DownloadDecision>[];
  for (final task in ordered) {
    if (running >= limits.atOnce) {
      decisions.add(HoldDownload(task.taskId, DownloadHold.slot));
      continue;
    }
    if ((bySource[task.sourceId] ?? 0) >= limits.perSource) {
      decisions.add(HoldDownload(task.taskId, DownloadHold.slot));
      continue;
    }
    // A file of unknown size is let through: the size is unknown precisely because it has never
    // started, and refusing every such task would mean nothing ever downloaded. The floor is checked
    // again by the post-processor, and the transport stops when the disk really is full.
    final needs = task.bytesTotal;
    if (needs != null && freeSpace - needs < limits.freeSpaceFloorBytes) {
      decisions.add(HoldDownload(task.taskId, DownloadHold.storage));
      continue;
    }

    decisions.add(StartDownload(task.taskId));
    running++;
    bySource[task.sourceId] = (bySource[task.sourceId] ?? 0) + 1;
    if (needs != null) freeSpace -= needs;
  }
  return decisions;
}

/// The hold that applies to every task at once, or null when the queue may run.
DownloadHold? _wholeQueueHold(
  DownloadLimits limits,
  DownloadConditions conditions,
) {
  if (!conditions.network.isUsable) return DownloadHold.network;
  if (limits.unmeteredOnly && conditions.network == NetworkKind.metered) {
    return DownloadHold.network;
  }
  if (conditions.freeSpaceBytes <= limits.freeSpaceFloorBytes) {
    return DownloadHold.storage;
  }
  return null;
}

/// Priority first, then the oldest request, then the lowest id.
///
/// The last is not arbitrary: without it two tasks asked for in the same millisecond would order
/// differently from one run to the next, and a queue that shuffles itself is one nobody can follow.
int _mostWantedFirst(DownloadCandidate a, DownloadCandidate b) {
  final byPriority = b.priority.compareTo(a.priority);
  if (byPriority != 0) return byPriority;
  final byAge = a.askedAt.compareTo(b.askedAt);
  if (byAge != 0) return byAge;
  return a.taskId.compareTo(b.taskId);
}
