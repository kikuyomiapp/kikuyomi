import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi_platform_adapters/src/audio/smtc_bridge.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:smtc_windows/smtc_windows.dart';

const s = 1000;

/// SMTC that records each call as it starts, can hold calls until released, and presses buttons on
/// request.
final class FakeControls implements SmtcControls {
  final calls = <Object>[];
  final _buttons = StreamController<PressedButton>.broadcast();

  /// While set, every call waits for it before finishing.
  Completer<void>? hold;

  /// The next call with this name throws.
  String? failNext;

  Future<void> _record(String name, [Object? value]) async {
    calls.add(value == null ? name : (name, value));
    final held = hold;
    if (held != null) await held.future;
    if (failNext == name) {
      failNext = null;
      throw StateError('SMTC refused $name');
    }
  }

  @override
  Stream<PressedButton> get buttons => _buttons.stream;

  @override
  Future<void> enable() => _record('enable');

  @override
  Future<void> disable() => _record('disable');

  @override
  Future<void> updateMetadata(MusicMetadata metadata) =>
      _record('metadata', metadata);

  @override
  Future<void> clearMetadata() => _record('clear');

  @override
  Future<void> updateTimeline(PlaybackTimeline timeline) =>
      _record('timeline', timeline);

  @override
  Future<void> setPlaybackStatus(PlaybackStatus status) =>
      _record('status', status);

  void press(PressedButton button) => _buttons.add(button);
}

MediaSessionState playing({
  String title = 'One',
  String album = 'A Book',
  String? artist = 'An Author',
  int positionMs = 0,
  bool playing = true,
  bool buffering = false,
}) => MediaSessionState(
  title: title,
  album: album,
  artist: artist,
  durationMs: 600 * s,
  positionMs: positionMs,
  updatedAt: DateTime(2026, 9, 14),
  playing: playing,
  buffering: buffering,
  speed: 1.0,
);

(String, PlaybackTimeline) timelineAt(int positionMs) => (
  'timeline',
  PlaybackTimeline(startTimeMs: 0, endTimeMs: 600 * s, positionMs: positionMs),
);

void main() {
  late FakeControls controls;
  late SmtcBridge bridge;
  late List<FlutterErrorDetails> reported;
  late FlutterExceptionHandler? presentError;

  setUp(() {
    controls = FakeControls();
    bridge = SmtcBridge(controls);
    reported = [];
    presentError = FlutterError.onError;
    FlutterError.onError = reported.add;
  });

  tearDown(() => FlutterError.onError = presentError);

  Future<void> show(MediaSessionState? state) async {
    bridge.update(state);
    await pumpEventQueue();
  }

  test('shows the chapter, the book, its author and the timeline, then turns the controls on', () async {
    await show(playing(positionMs: 90 * s));
    expect(controls.calls, [
      (
        'metadata',
        const MusicMetadata(title: 'One', album: 'A Book', artist: 'An Author'),
      ),
      timelineAt(90 * s),
      ('status', PlaybackStatus.playing),
      'enable',
    ]);
  });

  test(
    'sends a missing author as blank, so the last book\'s does not linger',
    () async {
      await show(playing(artist: null));
      expect(controls.calls.first, (
        'metadata',
        const MusicMetadata(title: 'One', album: 'A Book', artist: ''),
      ));
    },
  );

  test('sends only what changed', () async {
    await show(playing());
    controls.calls.clear();

    await show(playing(positionMs: 120 * s));
    expect(controls.calls, [timelineAt(120 * s)]);
  });

  test('names the new chapter when playback reaches it', () async {
    await show(playing());
    controls.calls.clear();

    await show(playing(title: 'Two', positionMs: 300 * s));
    expect(controls.calls, [
      (
        'metadata',
        const MusicMetadata(title: 'Two', album: 'A Book', artist: 'An Author'),
      ),
      timelineAt(300 * s),
    ]);
  });

  test('shows a pause as it happens', () async {
    await show(playing());
    controls.calls.clear();

    await show(playing(playing: false));
    expect(controls.calls, [('status', PlaybackStatus.paused)]);
  });

  test('keeps showing a book that buffers while it plays as playing', () async {
    await show(playing());
    controls.calls.clear();

    await show(playing(buffering: true));
    expect(controls.calls, isEmpty);
  });

  test('never sends a position outside the book', () async {
    await show(playing(positionMs: 700 * s));
    expect(controls.calls, contains(timelineAt(600 * s)));
  });

  test('removes the controls when the book closes', () async {
    await show(playing());
    controls.calls.clear();

    await show(null);
    expect(controls.calls, [
      ('status', PlaybackStatus.closed),
      'disable',
      'clear',
    ]);
  });

  test('has nothing to remove before a book is open', () async {
    await show(null);
    expect(controls.calls, isEmpty);
  });

  test('shows everything again for the next book', () async {
    await show(playing());
    await show(null);
    controls.calls.clear();

    await show(playing());
    expect(controls.calls, hasLength(4));
    expect(controls.calls.last, 'enable');
  });

  test(
    'applies one update at a time, skipping any overtaken while it waited',
    () async {
      controls.hold = Completer<void>();
      bridge.update(playing());
      await pumpEventQueue();
      bridge
        ..update(playing(title: 'Two'))
        ..update(playing(title: 'Three', positionMs: 600 * s));
      await pumpEventQueue();
      expect(controls.calls, hasLength(1));

      final held = controls.hold!;
      controls.hold = null;
      held.complete();
      await pumpEventQueue();

      expect(controls.calls, [
        (
          'metadata',
          const MusicMetadata(
            title: 'One',
            album: 'A Book',
            artist: 'An Author',
          ),
        ),
        timelineAt(0),
        ('status', PlaybackStatus.playing),
        'enable',
        (
          'metadata',
          const MusicMetadata(
            title: 'Three',
            album: 'A Book',
            artist: 'An Author',
          ),
        ),
        timelineAt(600 * s),
      ]);
    },
  );

  test('reports a failed update, and sends everything with the next', () async {
    controls.failNext = 'timeline';
    await show(playing());
    expect(reported, hasLength(1));
    controls.calls.clear();

    await show(playing(positionMs: 5 * s));
    expect(controls.calls, [
      (
        'metadata',
        const MusicMetadata(title: 'One', album: 'A Book', artist: 'An Author'),
      ),
      timelineAt(5 * s),
      ('status', PlaybackStatus.playing),
      'enable',
    ]);
  });

  test('removes controls a failed update may have left showing', () async {
    controls.failNext = 'metadata';
    await show(playing());
    controls.calls.clear();

    await show(null);
    expect(controls.calls, [
      ('status', PlaybackStatus.closed),
      'disable',
      'clear',
    ]);
  });

  group('buttons', () {
    late List<MediaCommand> commands;
    late StreamSubscription<MediaCommand> subscription;

    setUp(() {
      commands = [];
      subscription = bridge.commands.listen(commands.add);
    });

    tearDown(() => subscription.cancel());

    Future<void> press(PressedButton button) async {
      controls.press(button);
      await pumpEventQueue();
    }

    test('play and pause reach the book as they are', () async {
      await press(PressedButton.play);
      await press(PressedButton.pause);
      expect(commands, [isA<MediaPlay>(), isA<MediaPause>()]);
    });

    test('stop pauses, keeping the book where it was', () async {
      await press(PressedButton.stop);
      expect(commands, [isA<MediaPause>()]);
    });

    test('next and fast-forward skip forward', () async {
      await press(PressedButton.next);
      await press(PressedButton.fastForward);
      expect(commands, [isA<MediaSkipForward>(), isA<MediaSkipForward>()]);
    });

    test('previous and rewind skip back', () async {
      await press(PressedButton.previous);
      await press(PressedButton.rewind);
      expect(commands, [isA<MediaSkipBackward>(), isA<MediaSkipBackward>()]);
    });

    test('buttons an audiobook has no use for do nothing', () async {
      await press(PressedButton.record);
      await press(PressedButton.channelUp);
      await press(PressedButton.channelDown);
      expect(commands, isEmpty);
    });
  });
}
