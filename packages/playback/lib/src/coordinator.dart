import 'dart:async';
import 'dart:math' as math;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'engine.dart';
import 'listening_sessions.dart';
import 'media.dart';
import 'player_state.dart';
import 'progress_tracker.dart';
import 'sleep_timer.dart';
import 'smart_rewind.dart';

/// What the coordinator needs to open a book.
final class PlaybackRequest {
  const PlaybackRequest({
    required this.bookId,
    required this.timeline,
    this.resumeFrom,
    this.pausedFor = Duration.zero,
    this.speed = 1.0,
  });

  final int bookId;
  final Timeline timeline;

  /// The saved position, or null to start from the beginning.
  final ChapterPosition? resumeFrom;

  /// How long ago the book was last played, for smart rewind.
  final Duration pausedFor;

  /// The book's remembered speed (§4.3).
  final double speed;
}

/// §6.1's coordinator: the brain of playback, in pure Dart.
///
/// It owns the open book and its Timeline, turns user and system commands into engine operations,
/// feeds the progress tracker, the listening-session recorder and the sleep timer, persists what
/// they produce, and publishes a single [PlayerState].
///
/// Every command and every engine event runs through one serial queue. Without it, a seek could
/// interleave with a position event whose progress write is still in flight, and the last write
/// would be whichever finished second rather than whichever happened second.
///
/// Recovery from a stream error, per §6.3: one transparent re-resolve and reload at the same
/// position. It is re-armed by the next user action rather than by time passing, so a source that
/// fails every few seconds surfaces as an error instead of retrying forever.
///
/// The coordinator does not own the engine and does not dispose it.
final class PlaybackCoordinator {
  PlaybackCoordinator({
    required PlaybackEngine engine,
    required MediaResolver resolver,
    required PlaybackStore store,
    required Clock clock,
    SmartRewind? smartRewind,
    SleepTimer? sleepTimer,
    this.previousChapterThreshold = const Duration(seconds: 3),
    this.seekLandingTolerance = const Duration(milliseconds: 500),
  }) : _engine = engine,
       _resolver = resolver,
       _store = store,
       _clock = clock,
       _smartRewind = smartRewind ?? SmartRewind(),
       _sleepTimer = sleepTimer ?? SleepTimer(clock: clock) {
    _events = _engine.events.listen(
      (event) =>
          unawaited(_serial(() => _onEvent(event)).catchError(_onUnexpected)),
    );
  }

  /// "Previous chapter" restarts the current chapter when playback is further into it than this,
  /// and goes to the previous chapter otherwise. The usual convention in media players.
  final Duration previousChapterThreshold;

  /// How far short of where a seek or load was sent the engine may report being, and still be
  /// taken to be there.
  ///
  /// The just_audio backend on Windows settles a seek just short of where it was sent: at normal
  /// speed, a seek to 9000 ms reports 8999 ms. Taken literally, a position short of a chapter's
  /// start belongs to the previous chapter: the player names the wrong chapter, progress is saved
  /// at the end of the previous one, and "next chapter" seeks to the same start again and again
  /// without moving. A position this close short of the destination is read as the destination
  /// itself. The margin is generous because nothing else reports such a position: playback only
  /// moves forwards from where it was sent.
  final Duration seekLandingTolerance;

  final PlaybackEngine _engine;
  final MediaResolver _resolver;
  final PlaybackStore _store;
  final Clock _clock;
  final SmartRewind _smartRewind;
  final SleepTimer _sleepTimer;

  late final StreamSubscription<EngineEvent> _events;
  final _states = StreamController<PlayerState>.broadcast();
  PlayerState _state = const PlayerIdle();
  _Session? _session;
  SleepTimerState _sleepState = const SleepTimerOff();
  Future<void> _tail = Future.value();

  PlayerState get state => _state;
  Stream<PlayerState> get states => _states.stream;

  /// Opens a book, resuming it with smart rewind applied, without starting playback.
  Future<void> open(PlaybackRequest request) => _serial(() async {
    await _closeSession();
    _emit(PlayerLoading(request.bookId));
    // A rewind owed to a previous book's sleep timer does not carry over to this one.
    _sleepTimer.takeResumeRewind();

    final timeline = request.timeline;
    try {
      final items = await _resolve(timeline, refresh: false);
      final saved = request.resumeFrom;
      final start = saved == null
          ? ChapterPosition(chapterId: timeline.chapterIds.first, offsetMs: 0)
          : _smartRewind.resumeFrom(saved, request.pausedFor);
      final startAt = timeline.queuePositionOfChapter(start);

      await _engine.load(items, startAt: startAt);
      await _engine.setSpeed(request.speed);
      await _engine.setVolume(1.0);

      final session = _Session(
        bookId: request.bookId,
        timeline: timeline,
        tracker: ProgressTracker(timeline: timeline, clock: _clock),
        recorder: ListeningSessionRecorder(
          bookId: request.bookId,
          timeline: timeline,
          clock: _clock,
        ),
        speed: request.speed,
        position: startAt,
      );
      session.tracker.onLoaded(startAt);
      _session = session;
      _publish();
    } catch (error) {
      _session = null;
      _emit(PlayerFailed(bookId: request.bookId, error: error));
    }
  });

  Future<void> play() => _serial(() async {
    final session = _session;
    if (session == null || session.playing) return;
    session.retried = false;

    if (session.error != null) {
      session.error = null;
      if (!await _reload(session, refresh: true)) return;
    }

    if (session.finished) {
      session.finished = false;
      await _seekInternal(session, 0);
    } else {
      final pausedAt = session.pausedAt;
      final pause = pausedAt == null
          ? Duration.zero
          : _clock.now().difference(pausedAt);
      // Smart rewind and the sleep timer's rewind are independent; the larger one wins.
      final smart = _smartRewind.rewindAfter(pause);
      final sleep = _sleepTimer.takeResumeRewind();
      final rewind = smart > sleep ? smart : sleep;
      if (rewind > Duration.zero) {
        final here = session.timeline.chapterPositionOfQueue(session.position);
        final back = ChapterPosition(
          chapterId: here.chapterId,
          offsetMs: math.max(0, here.offsetMs - rewind.inMilliseconds),
        );
        await _seekInternal(session, session.timeline.globalOf(back));
      }
    }

    await _engine.play();
    session.playing = true;
    session.pausedAt = null;
    _sleepTimer.onPlaying();
    session.recorder.onPlay(globalMs: session.globalMs, speed: session.speed);
    _publish();
  });

  Future<void> pause() => _serial(_pauseInternal);

  /// A seek to a position in book-global time, which is what the scrubber and skip buttons produce.
  Future<void> seekTo(int globalMs) => _serial(() async {
    final session = _session;
    if (session == null) return;
    session.retried = false;
    session.finished = false;
    await _seekInternal(session, globalMs);
    _publish();
  });

  /// Skips forwards, or backwards for a negative [by], clamped to the book.
  Future<void> skip(Duration by) => _serial(() async {
    final session = _session;
    if (session == null) return;
    session.retried = false;
    session.finished = false;
    await _seekInternal(session, session.globalMs + by.inMilliseconds);
    _publish();
  });

  /// Moves to the next chapter, or the next embedded marker in a single-chapter book.
  Future<void> nextChapter() => _serial(() async {
    final session = _session;
    if (session == null) return;
    final entries = session.timeline.navigation;
    final index = entries.indexOf(
      session.timeline.navigationEntryAt(session.globalMs),
    );
    if (index + 1 >= entries.length) return;
    session.retried = false;
    await _seekInternal(session, entries[index + 1].startMs);
    _publish();
  });

  /// Restarts the current chapter, or moves to the previous one near its start. See
  /// [previousChapterThreshold].
  Future<void> previousChapter() => _serial(() async {
    final session = _session;
    if (session == null) return;
    final timeline = session.timeline;
    final global = session.globalMs;
    final current = timeline.navigationEntryAt(global);
    final index = timeline.navigation.indexOf(current);
    final intoChapter = global - current.startMs;
    final target =
        index == 0 || intoChapter > previousChapterThreshold.inMilliseconds
        ? current.startMs
        : timeline.navigation[index - 1].startMs;
    session.retried = false;
    session.finished = false;
    await _seekInternal(session, target);
    _publish();
  });

  /// §6.5: 0.5x to 3.5x. Remembered for the book.
  Future<void> setSpeed(double speed) => _serial(() async {
    if (speed < 0.5 || speed > 3.5) {
      throw ArgumentError.value(speed, 'speed', 'must be between 0.5 and 3.5');
    }
    final session = _session;
    if (session == null || speed == session.speed) return;
    await _engine.setSpeed(speed);
    await _saveSession(
      session.recorder.onSpeedChanged(globalMs: session.globalMs, speed: speed),
    );
    session.speed = speed;
    await _store.saveSpeed(bookId: session.bookId, speed: speed);
    _publish();
  });

  Future<void> startSleepTimer(SleepTimerTarget target) => _serial(() async {
    final session = _session;
    if (session == null) return;
    _sleepTimer.start(target);
    await _applySleepTimer(session, evenWhenPaused: true);
    _publish();
  });

  Future<void> extendSleepTimer(Duration by) => _serial(() async {
    final session = _session;
    if (session == null) return;
    _sleepTimer.extend(by);
    await _applySleepTimer(session, evenWhenPaused: true);
    _publish();
  });

  Future<void> cancelSleepTimer() => _serial(() async {
    final session = _session;
    if (session == null) return;
    _sleepTimer.cancel();
    _sleepState = const SleepTimerOff();
    await _setVolume(session, 1.0);
    _publish();
  });

  /// An interruption such as a phone call or navigation prompt took the audio. §6.4 saves progress
  /// immediately.
  Future<void> onInterruption() => _serial(_pauseInternal);

  /// The app moved to the background. §6.4 saves progress immediately; playback continues.
  Future<void> onBackgrounded() => _serial(() async {
    final session = _session;
    if (session == null) return;
    await _saveProgress(session, session.tracker.onBackgrounded());
  });

  /// Stops the open book, saving its progress and listening, and stops listening to the engine.
  Future<void> close() async {
    await _serial(_closeSession);
    await _events.cancel();
    _emit(const PlayerIdle());
    await _states.close();
  }

  // Internals. Everything below assumes it is already running inside the serial queue.

  Future<void> _onEvent(EngineEvent event) async {
    final session = _session;
    if (session == null) return;
    switch (event) {
      case EnginePositionChanged(:final position):
        // Spike (b): after completion the engine reports position zero. It is not a position.
        if (session.finished) return;
        session.position = _settle(session, position);
        await _saveProgress(
          session,
          session.tracker.onPosition(session.position),
        );
        await _saveSession(session.recorder.onPosition(session.globalMs));
        await _applySleepTimer(session);
        _publish();
      case EngineItemChanged():
        // Positions arrive with their item index, so there is nothing extra to track.
        break;
      case EngineBufferingChanged(:final buffering):
        session.buffering = buffering;
        _publish();
      case EngineCompleted():
        session.playing = false;
        session.finished = true;
        session.pausedAt = _clock.now();
        session.position = session.timeline.queuePositionAt(
          session.timeline.totalDurationMs,
        );
        _sleepTimer.onPaused();
        await _saveProgress(session, session.tracker.onCompleted());
        await _saveSession(
          session.recorder.onStop(session.timeline.totalDurationMs),
        );
        _publish();
      case EngineFailed(:final error):
        if (session.retried) {
          await _fail(session, error);
        } else {
          session.retried = true;
          await _reload(session, refresh: true);
        }
    }
  }

  Future<void> _pauseInternal() async {
    final session = _session;
    if (session == null || !session.playing) return;
    await _engine.pause();
    session.playing = false;
    session.pausedAt = _clock.now();
    _sleepTimer.onPaused();
    await _saveProgress(session, session.tracker.onPause());
    await _saveSession(session.recorder.onStop(session.globalMs));
    _publish();
  }

  Future<void> _seekInternal(_Session session, int globalMs) async {
    final timeline = session.timeline;
    final from = session.globalMs;
    final destination = timeline.queuePositionAt(globalMs);
    await _engine.seek(destination);
    session.position = destination;
    session.landing = destination;
    await _saveProgress(session, session.tracker.onSeek(destination));
    await _saveSession(
      session.recorder.onSeek(
        fromGlobalMs: from,
        toGlobalMs: timeline.globalOfQueue(destination),
      ),
    );
  }

  /// The engine's [reported] position, or where it was last sent if [reported] falls just short of
  /// that. See [seekLandingTolerance].
  ///
  /// The destination is kept until the next seek or load rather than cleared once passed. Playback
  /// only moves forwards from it, so nothing else reports a position just short of it, and a stale
  /// sample from before a backwards seek cannot clear it early.
  QueuePosition _settle(_Session session, QueuePosition reported) {
    final timeline = session.timeline;
    final shortBy =
        timeline.globalOfQueue(session.landing) -
        timeline.globalOfQueue(reported);
    return shortBy > 0 && shortBy <= seekLandingTolerance.inMilliseconds
        ? session.landing
        : reported;
  }

  /// Re-resolves every file and reloads at the current position. Returns whether it worked.
  Future<bool> _reload(_Session session, {required bool refresh}) async {
    try {
      final items = await _resolve(session.timeline, refresh: refresh);
      session.landing = session.position;
      await _engine.load(items, startAt: session.position);
      await _engine.setSpeed(session.speed);
      await _engine.setVolume(session.volume);
      if (session.playing) await _engine.play();
      return true;
    } catch (error) {
      await _fail(session, error);
      return false;
    }
  }

  Future<void> _fail(_Session session, Object error) async {
    if (session.playing) {
      session.playing = false;
      session.pausedAt = _clock.now();
      _sleepTimer.onPaused();
      await _saveProgress(session, session.tracker.onPause());
      await _saveSession(session.recorder.onStop(session.globalMs));
    }
    session.error = error;
    _publish();
  }

  Future<void> _applySleepTimer(
    _Session session, {
    bool evenWhenPaused = false,
  }) async {
    if (!_sleepTimer.isActive || (!session.playing && !evenWhenPaused)) return;
    final global = session.globalMs;
    final entry = session.timeline.navigationEntryAt(global);
    final state = _sleepTimer.poll(
      chapterRemaining: Duration(milliseconds: entry.endMs - global),
      speed: session.speed,
    );
    switch (state) {
      case SleepTimerRunning(:final volume):
        _sleepState = state;
        await _setVolume(session, volume);
      case SleepTimerExpired():
        _sleepState = const SleepTimerOff();
        await _pauseInternal();
        await _setVolume(session, 1.0);
      case SleepTimerOff():
        _sleepState = state;
    }
  }

  Future<void> _setVolume(_Session session, double volume) async {
    if (volume == session.volume) return;
    await _engine.setVolume(volume);
    session.volume = volume;
  }

  Future<void> _closeSession() async {
    final session = _session;
    if (session == null) return;
    await _pauseInternal();
    _session = null;
  }

  Future<List<EngineItem>> _resolve(
    Timeline timeline, {
    required bool refresh,
  }) async {
    final resolved = <int, ResolvedMedia>{};
    return [
      for (final item in timeline.queue)
        EngineItem(
          item: item,
          media: resolved[item.fileId] ??= await _resolver.resolve(
            item.fileId,
            refresh: refresh,
          ),
        ),
    ];
  }

  Future<void> _saveProgress(
    _Session session,
    ChapterPosition? position,
  ) async {
    if (position == null) return;
    await _store.saveProgress(
      bookId: session.bookId,
      position: position,
      globalMs: session.timeline.globalOf(position),
    );
  }

  Future<void> _saveSession(ListeningSession? listening) async {
    if (listening != null) await _store.saveSession(listening);
  }

  void _publish() {
    final session = _session;
    if (session == null) {
      _emit(const PlayerIdle());
      return;
    }
    final error = session.error;
    if (error != null) {
      _emit(PlayerFailed(bookId: session.bookId, error: error));
      return;
    }
    final timeline = session.timeline;
    final global = session.globalMs;
    _emit(
      PlayerReady(
        bookId: session.bookId,
        position: timeline.chapterPositionAt(global),
        globalMs: global,
        totalMs: timeline.totalDurationMs,
        entry: timeline.navigationEntryAt(global),
        playing: session.playing,
        buffering: session.buffering,
        speed: session.speed,
        sleepTimer: _sleepTimer.isActive ? _sleepState : const SleepTimerOff(),
        finished: session.finished,
      ),
    );
  }

  void _emit(PlayerState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  /// An event handler threw something it did not anticipate. Surface it rather than lose it.
  void _onUnexpected(Object error) {
    final session = _session;
    if (session == null) return;
    session.error = error;
    _publish();
  }

  /// Runs [task] after everything already queued, and keeps the queue alive if [task] fails.
  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

final class _Session {
  _Session({
    required this.bookId,
    required this.timeline,
    required this.tracker,
    required this.recorder,
    required this.speed,
    required this.position,
  }) : landing = position;

  final int bookId;
  final Timeline timeline;
  final ProgressTracker tracker;
  final ListeningSessionRecorder recorder;
  double speed;
  QueuePosition position;

  /// Where the engine was last sent, by the load that opened the book, a reload or a seek. See
  /// [PlaybackCoordinator.seekLandingTolerance].
  QueuePosition landing;
  bool playing = false;
  bool buffering = false;
  bool finished = false;

  /// Whether the one automatic recovery §6.3 allows has been spent since the last user action.
  bool retried = false;
  double volume = 1.0;
  DateTime? pausedAt;
  Object? error;

  int get globalMs => timeline.globalOfQueue(position);
}
