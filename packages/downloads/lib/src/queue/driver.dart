/// The thing that actually runs the queue (§5.2).
///
/// Everything it needs is behind an interface or a function, so the whole of it is testable with a
/// fake store, a fake transport and a resolver that answers from a map. That is the point of ADR-0007
/// keeping the queue on our side of the line: the decisions live here, and the part that cannot be
/// tested is the hundred lines that talk to `WorkManager`.
///
/// One pass of [pump] is the whole cycle: let any retries that are due rejoin the queue, ask the
/// store what could start, ask the policy what may start, and act on each answer. Reports from the
/// transport arrive separately and are applied through §5.3's state machine, which is what makes a
/// late report — a completion for a task the listener cancelled a moment ago — do nothing instead of
/// crashing.
///
/// Nothing here loops or waits on a timer. When to pump is the app's decision: after enqueueing, when
/// the network changes, and periodically while there is work. A driver that owned a timer would be a
/// driver that could not be tested without one. The one case the driver keeps for itself is a task
/// finishing, because it is the only thing that knows one has, and waiting out a tick after every
/// file would make a fifteen-file book take seven minutes of nothing happening.
library;

import 'dart:async';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../transport.dart';
import 'backoff.dart';
import 'scheduler_policy.dart';
import 'transitions.dart';

/// What the device can offer, asked afresh each pass.
///
/// A record rather than an interface: there are two facts, both of which the platform answers, and
/// neither of which the driver can do anything about.
typedef DeviceConditions = ({NetworkKind network, int? freeSpaceBytes});

/// Where a finished file ends up, after §5.2's post-processor has had it.
///
/// Given the task and the path the transport left the bytes at, it returns the path the file will
/// live at. The checking, probing and atomic move are its business; the driver only wants to know
/// what to write down. Without one, the transport's path is taken as final, which is what the tests
/// and the first working version do.
typedef DownloadPostProcessor = Future<String> Function(
  DownloadSubject subject,
  String downloadedPath,
);

/// Runs the download queue.
final class DownloadDriver {
  DownloadDriver({
    required DownloadStore store,
    required DownloadTransport transport,
    required Future<ResolvedMedia> Function(int mediaFileId) resolve,
    required Future<DeviceConditions> Function() conditions,
    required Clock clock,
    this.limits = const DownloadLimits(),
    this.backoff = const DownloadBackoff(),
    DownloadPostProcessor? postProcess,
    String Function(DownloadSubject subject)? nameFile,
  }) : _store = store,
       _transport = transport,
       _resolve = resolve,
       _conditions = conditions,
       _clock = clock,
       _postProcess = postProcess,
       _nameFile = nameFile ?? _defaultName;

  final DownloadStore _store;
  final DownloadTransport _transport;
  final Future<ResolvedMedia> Function(int mediaFileId) _resolve;
  final Future<DeviceConditions> Function() _conditions;
  final Clock _clock;
  final DownloadPostProcessor? _postProcess;
  final String Function(DownloadSubject subject) _nameFile;

  /// §5.2's caps and policies.
  final DownloadLimits limits;

  /// §5.5's retry schedule.
  final DownloadBackoff backoff;

  /// How many times running a task may be sent back to its source by a refused address before the
  /// refusal is treated as a failure (§5.4).
  static const maxUrlRejections = 2;

  StreamSubscription<TransportReport>? _reports;

  /// What the driver believes each task's state is, so a report can be judged against §5.3 without a
  /// read. Only tasks it has acted on are here; anything else is looked up.
  final _believed = <int, DownloadState>{};

  /// How many times running a task has had its address refused, since it last got anywhere.
  ///
  /// §5.4 charges a stale address no attempt, which is right and, on its own, unbounded: a source
  /// that hands out an address it then refuses would have the queue asking and being refused as fast
  /// as the network allows. After [maxUrlRejections] the task is failed instead, so §5.5's backoff
  /// paces it like anything else that is not working.
  final _rejections = <int, int>{};

  var _pumping = false;
  var _pumpAgain = false;

  /// Begins listening to the transport. Until this is called, nothing the transport says is acted on.
  void start() {
    _reports ??= _transport.reports.listen(
      (report) => unawaited(_onReport(report)),
    );
  }

  /// One pass of the queue.
  ///
  /// Safe to call at any time and from anywhere: a pass that finds nothing to do costs two reads, and
  /// a call arriving while a pass is running asks for another rather than running alongside it. That
  /// second part is what keeps §5.2's caps true — two passes that each read what is running before
  /// either had started anything would each authorise a full set of downloads — and it is what lets
  /// the driver ask for a pass from inside one.
  Future<void> pump() async {
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        await _onePass();
      } while (_pumpAgain);
    } finally {
      _pumping = false;
    }
  }

  /// Puts right whatever the last run of the app left behind (§5.2).
  ///
  /// The table says what was in flight and the transport says what it is still carrying; where they
  /// disagree, the table is out of date. `resolving` and `processing` both happen inside a single pass
  /// and so cannot survive a restart, and a `downloading` task the transport has never heard of is one
  /// whose job died with the process. Each of those goes back into the queue.
  ///
  /// This is not housekeeping. A task left in flight counts against §5.2's caps for ever, so two of
  /// them are enough to stop a source from ever downloading anything again.
  Future<void> reconcile() async {
    final inFlight = await _store.readInFlight();
    if (inFlight.isEmpty) return;
    final carrying = await _transport.carrying();
    for (final task in inFlight) {
      final transportId = task.transportTaskId;
      if (task.state == DownloadState.downloading &&
          transportId != null &&
          carrying.contains(transportId)) {
        // Still moving. Writing it down is what lets its next report past §5.3, which would otherwise
        // judge it against a state the driver had never seen.
        _believed[task.taskId] = DownloadState.downloading;
        continue;
      }
      await _store.saveTransportId(task.taskId, null);
      await _moveTo(task.taskId, DownloadState.queued);
    }
  }

  Future<void> _onePass() async {
    await _releaseRetries();

    final candidates = await _store.readStartable(limit: limits.atOnce * 4);
    if (candidates.isEmpty) return;

    final device = await _conditions();
    final decisions = chooseDownloads(
      candidates: candidates,
      limits: limits,
      conditions: DownloadConditions(
        network: device.network,
        freeSpaceBytes: device.freeSpaceBytes,
        runningBySource: await _store.countRunningBySource(),
      ),
    );

    for (final decision in decisions) {
      switch (decision) {
        case HoldDownload(:final taskId, :final reason):
          await _moveTo(taskId, DownloadState.waiting, hold: reason);
        case StartDownload(:final taskId):
          await _begin(taskId);
      }
    }
  }

  /// Stops [taskId], keeping what has arrived.
  Future<void> pause(int taskId) async {
    await _transport.pause(taskId);
    await _moveTo(taskId, DownloadState.paused);
  }

  /// Gives up on [taskId] and throws away what has arrived.
  Future<void> cancel(int taskId) async {
    await _transport.cancel(taskId);
    await _store.saveTransportId(taskId, null);
    await _moveTo(taskId, DownloadState.cancelled);
  }

  /// Stops listening. The app keeps one driver for as long as it runs, so this is for tests and for
  /// shutdown.
  Future<void> dispose() async {
    await _reports?.cancel();
    _reports = null;
  }

  /// Lets any retryable failure whose wait has elapsed rejoin the queue (§5.5).
  Future<void> _releaseRetries() async {
    for (final taskId in await _store.readRetryDue(_clock.now())) {
      await _moveTo(taskId, DownloadState.queued);
    }
  }

  /// Resolves [taskId] if it needs it and hands it to the transport.
  Future<void> _begin(int taskId) async {
    final subject = await _store.readSubject(taskId);
    // A listener may have cancelled the book, or taken it out of the library, between the decision
    // and the act. Nothing to do, and nothing wrong.
    if (subject == null) return;

    await _moveTo(taskId, DownloadState.resolving);

    DownloadRequest request;
    // A task sent back by a refused address must ask again, however fresh the one it holds looks:
    // that address is precisely the one the site just turned down (§5.4).
    final mustAskAgain = subject.state == DownloadState.needsResolve;
    if (!mustAskAgain && subject.hasUsableRequest(_clock.now())) {
      request = subject.request!;
    } else {
      try {
        // §5.4: just in time, never at enqueue. The URL a task will use cannot be worked out when the
        // listener queues a book, because many sources hand out addresses that expire in minutes.
        final media = await _resolve(subject.mediaFileId);
        request = DownloadRequest(
          url: media.uri.toString(),
          headers: media.headers,
        );
        await _store.saveResolution(
          taskId,
          request: request,
          expiresAt: media.expiresAt,
        );
      } catch (error) {
        await _failed(subject, '$error', permanent: false);
        return;
      }
    }

    await _moveTo(taskId, DownloadState.downloading);
    try {
      final transportId = await _transport.start(
        taskId: taskId,
        request: request,
        fileName: _nameFile(subject),
      );
      await _store.saveTransportId(taskId, transportId);
    } catch (error) {
      await _failed(subject, '$error', permanent: false);
    }
  }

  /// Applies what the transport said, through §5.3.
  Future<void> _onReport(TransportReport report) async {
    switch (report) {
      case TransportProgress(
        :final taskId,
        :final bytesDone,
        :final bytesTotal,
      ):
        // Progress is not a transition, so it needs no judgement from the state machine — but a
        // report for a task that has finished or been cancelled is still worth nothing.
        if (await _stateOf(taskId) != DownloadState.downloading) return;
        await _store.saveProgress(
          taskId,
          bytesDone: bytesDone,
          bytesTotal: bytesTotal,
        );

      case TransportFinished(:final taskId, :final path, :final bytesTotal):
        if (!await _canMove(taskId, const DownloadBytesArrived())) return;
        if (bytesTotal != null) {
          await _store.saveProgress(
            taskId,
            bytesDone: bytesTotal,
            bytesTotal: bytesTotal,
          );
        }
        await _moveTo(taskId, DownloadState.processing);
        final subject = await _store.readSubject(taskId);
        if (subject == null) return;
        try {
          final finalPath =
              await (_postProcess?.call(subject, path) ?? Future.value(path));
          await _store.saveCompleted(taskId, localPath: finalPath);
          await _store.saveTransportId(taskId, null);
          _believed[taskId] = DownloadState.completed;
          _rejections.remove(taskId);
          _slotFreed();
        } catch (error) {
          // A file that arrived but is not what it claimed to be will not become one by being
          // fetched again from the same place, so §5.2's checks fail it for good.
          await _failed(subject, '$error', permanent: true);
        }

      case TransportFailed(
        :final taskId,
        :final message,
        :final permanent,
        :final urlRejected,
      ):
        if (urlRejected) {
          final refusals = (_rejections[taskId] ?? 0) + 1;
          if (refusals <= maxUrlRejections) {
            // §5.4: not a failure. The address was perishable, which is the source working as
            // designed, so nothing counts against the file's attempts.
            if (!await _canMove(taskId, const DownloadUrlRejected())) return;
            _rejections[taskId] = refusals;
            await _moveTo(taskId, DownloadState.needsResolve);
            _slotFreed();
            return;
          }
          // Asked and refused this many times running, it is no longer a perishable address; it is a
          // source that will not serve this file. Failing it hands the pacing to §5.5 rather than
          // letting the queue ask as fast as the network answers.
          final subject = await _store.readSubject(taskId);
          if (subject == null) return;
          _rejections.remove(taskId);
          await _failed(
            subject,
            'the source kept refusing the address it gave ($message)',
            permanent: false,
          );
          return;
        }
        final subject = await _store.readSubject(taskId);
        if (subject == null) return;
        if (!await _canMove(taskId, DownloadFailed(permanent: permanent))) {
          return;
        }
        await _failed(subject, message, permanent: permanent);
    }
  }

  /// Records a failure and works out whether there is another attempt in it (§5.5).
  Future<void> _failed(
    DownloadSubject subject,
    String error, {
    required bool permanent,
  }) async {
    final attempts = subject.attempts + 1;
    final retryAt = permanent
        ? null
        : backoff.after(attempts)?.let((wait) => _clock.now().add(wait));
    // Running out of attempts is what turns a retryable failure into a permanent one. The state
    // machine does not decide that; the schedule does.
    final noneLeft = !permanent && retryAt == null;
    await _store.saveFailure(
      subject.taskId,
      error: error,
      permanent: permanent || noneLeft,
      retryAt: retryAt,
    );
    _believed[subject.taskId] = permanent || noneLeft
        ? DownloadState.failedPermanent
        : DownloadState.failedRetryable;
    await _store.saveTransportId(subject.taskId, null);
    _slotFreed();
  }

  /// A task has stopped occupying one of §5.2's slots, so the next one need not wait for a tick.
  ///
  /// Deliberately not awaited: this is called from inside a pass as often as from a report, and [pump]
  /// folds a request made during a pass into one more pass after it rather than running a second
  /// alongside.
  void _slotFreed() => unawaited(pump());

  /// Writes [state] and remembers it, so the next report can be judged without a read.
  Future<void> _moveTo(
    int taskId,
    DownloadState state, {
    DownloadHold? hold,
  }) async {
    await _store.saveState(taskId, state, hold: hold);
    _believed[taskId] = state;
  }

  /// Whether [event] applies to what [taskId] is doing (§5.3).
  Future<bool> _canMove(int taskId, DownloadEvent event) async =>
      canAdvance(await _stateOf(taskId), event);

  /// What the driver believes [taskId] is doing.
  ///
  /// A task the driver has not acted on this run — one left downloading when the app was killed, say
  /// — is not in hand, and the safe answer is the state it was last seen in. Reading it back from the
  /// store would be better; until the reconciler exists (§5.2), an unknown task is treated as
  /// downloading, which is the state that lets a report through.
  Future<DownloadState> _stateOf(int taskId) async =>
      _believed[taskId] ?? DownloadState.downloading;

  /// What a downloaded file is called. The book and the file keep it unique without the transport
  /// needing to know anything about either.
  static String _defaultName(DownloadSubject subject) =>
      '${subject.bookId}_${subject.mediaFileId}';
}

extension<T extends Object> on T {
  /// Applies [transform] to this value. Saves a local for a nullable that has already been checked.
  R let<R>(R Function(T value) transform) => transform(this);
}
