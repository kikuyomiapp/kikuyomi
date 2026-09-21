/// When automatic backups run.
///
/// §8's Phase 1 makes backups automatic, and ADR-0008 explains why: a backup that waits for a button
/// protects the users who least need protecting. The rule chosen is to back up shortly after changes:
///
/// - A backup becomes due when anything a backup carries changes.
/// - It runs once changes have settled for [BackupScheduler.settle], but never later than
///   [BackupScheduler.longestWait] after the first change not yet backed up, since listening saves
///   progress every few seconds and would otherwise never settle.
/// - It also runs when the app goes to the background or closes, if a backup is due.
/// - With nothing changed, nothing is written.
///
/// Backups run one at a time. A change during one makes another due.
library;

import 'dart:async';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'backup_service.dart';

/// Runs backups by the rule above, against [Clock] and timers it is given, so it is tested without
/// waiting.
final class BackupScheduler {
  /// [backUp] writes one backup, as `BackupService.backUp` does. [changes] signals every change to what
  /// a backup carries. [startTimer] starts a timer; a real one unless a test gives another.
  BackupScheduler({
    required Future<BackupOutcome> Function() backUp,
    required Stream<void> changes,
    required SettingsStore settings,
    required Clock clock,
    Timer Function(Duration duration, void Function() callback)? startTimer,
    this.settle = const Duration(minutes: 3),
    this.longestWait = const Duration(minutes: 15),
  }) : _backUp = backUp,
       _changes = changes,
       _settings = settings,
       _clock = clock,
       _startTimer = startTimer ?? Timer.new;

  /// How long changes must stop for before a backup runs.
  final Duration settle;

  /// The longest a change waits to be backed up while changes keep coming.
  final Duration longestWait;

  final Future<BackupOutcome> Function() _backUp;
  final Stream<void> _changes;
  final SettingsStore _settings;
  final Clock _clock;
  final Timer Function(Duration, void Function()) _startTimer;

  final _outcomes = StreamController<BackupOutcome>.broadcast();
  StreamSubscription<void>? _subscription;
  Timer? _timer;

  /// When the first change not yet backed up was made, or null when nothing is due.
  DateTime? _dueSince;

  /// When the last change was made, or null when no change has been made since a backup started.
  DateTime? _lastChange;

  /// The backup under way, if one is.
  Future<BackupOutcome>? _running;

  /// Whether a backup came due while another ran, and should run as soon as it finishes.
  var _runAgain = false;

  /// Every backup's outcome, as it finishes.
  Stream<BackupOutcome> get outcomes => _outcomes.stream;

  /// Whether anything has changed since the last backup was written.
  bool get isDue => _dueSince != null;

  /// Starts listening for changes. Cheap: it reads one setting and subscribes, and backs nothing up
  /// until a change has settled.
  ///
  /// A backup still due when the app last stopped is due again now, counted from now.
  void start() {
    if (_subscription != null) return;
    if (_settings.read(AppSettings.backupDue) ?? false) {
      _dueSince = _lastChange = _clock.now();
      _schedule();
    }
    _subscription = _changes.listen((_) => _changed());
  }

  /// The app is going to the background or closing: backs up now if a backup is due. Completes once
  /// that backup, and any already under way, has finished.
  Future<void> appLeaving() async {
    final running = _running;
    if (running != null) await running;
    // A backup that came due while the last one ran may have started as it finished.
    if (_running case final started?) {
      await started;
    } else if (_dueSince != null) {
      await _run();
    }
  }

  /// Backs up now, whether or not anything changed, once any backup under way has finished: for a
  /// backup the user asks for, and after a new folder is chosen.
  Future<BackupOutcome> backUpNow() async {
    for (var running = _running; running != null; running = _running) {
      await running;
    }
    return _run();
  }

  /// Stops listening for changes and cancels the timer. A backup under way still finishes.
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _running;
    await _outcomes.close();
  }

  void _changed() {
    final now = _clock.now();
    if (_dueSince == null) {
      _dueSince = now;
      unawaited(_settings.write(AppSettings.backupDue, true));
    }
    _lastChange = now;
    _schedule();
  }

  /// Sets the timer for when the backup due should run.
  void _schedule() {
    final dueSince = _dueSince;
    final lastChange = _lastChange;
    if (dueSince == null || lastChange == null) return;
    final settled = lastChange.add(settle);
    final latest = dueSince.add(longestWait);
    final runAt = settled.isBefore(latest) ? settled : latest;
    final wait = runAt.difference(_clock.now());
    _timer?.cancel();
    _timer = _startTimer(wait.isNegative ? Duration.zero : wait, () {
      _timer = null;
      if (_running != null) {
        _runAgain = true;
      } else if (_dueSince != null) {
        unawaited(_run());
      }
    });
  }

  Future<BackupOutcome> _run() {
    _timer?.cancel();
    _timer = null;
    final wasDue = _dueSince != null;
    // Cleared as the backup starts: a change from here on is not in it, and makes another due.
    _dueSince = null;
    _lastChange = null;
    return _running = _attempt(wasDue: wasDue);
  }

  Future<BackupOutcome> _attempt({required bool wasDue}) async {
    BackupOutcome outcome;
    try {
      outcome = await _backUp();
    } catch (error, stackTrace) {
      outcome = BackupFailed(error, stackTrace);
    }
    final written = outcome is BackupWritten;
    if (written) {
      if (_dueSince == null) {
        unawaited(_settings.write(AppSettings.backupDue, null));
      }
    } else if (wasDue) {
      // Still due. Counted from now, so a folder that keeps failing is tried again when changes
      // settle or the longest wait passes, never on every progress save.
      _dueSince ??= _clock.now();
    }
    _running = null;
    _outcomes.add(outcome);
    if (_runAgain) {
      _runAgain = false;
      if (_dueSince != null) {
        // After a failure, wait as for any change rather than failing again at once.
        written ? unawaited(_run()) : _schedule();
      }
    }
    return outcome;
  }
}
