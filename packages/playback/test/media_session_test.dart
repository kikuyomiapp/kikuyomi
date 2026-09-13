import 'dart:async';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

const s = 1000;

QueuePosition q(int item, int offsetMs) =>
    QueuePosition(itemIndex: item, offsetMs: offsetMs);

/// Two chapters, one 300 s file each.
Timeline book() => Timeline.build(
  files: const [
    TimelineFile(id: 1, durationMs: 300 * s),
    TimelineFile(id: 2, durationMs: 300 * s),
  ],
  chapters: [
    TimelineChapter(
      id: 1,
      title: 'One',
      segments: const [TimelineSegment(fileId: 1)],
    ),
    TimelineChapter(
      id: 2,
      title: 'Two',
      segments: const [TimelineSegment(fileId: 2)],
    ),
  ],
);

/// Media controls that record what they were shown and press buttons on request.
final class FakeBridge implements MediaSessionBridge {
  final updates = <MediaSessionState?>[];
  final _commands = StreamController<MediaCommand>.broadcast();

  MediaSessionState get shown => updates.last!;

  @override
  void update(MediaSessionState? state) => updates.add(state);

  @override
  Stream<MediaCommand> get commands => _commands.stream;

  Future<void> press(MediaCommand command) async {
    _commands.add(command);
    await pumpEventQueue();
  }
}

void main() {
  late FakeClock clock;
  late FakeEngine engine;
  late PlaybackCoordinator coordinator;
  late FakeBridge bridge;
  late MediaSessionSync sync;
  late List<int> described;

  setUp(() {
    clock = FakeClock();
    engine = FakeEngine();
    coordinator = PlaybackCoordinator(
      engine: engine,
      resolver: FakeResolver(),
      store: FakeStore(),
      clock: clock,
    );
    bridge = FakeBridge();
    described = [];
    sync = MediaSessionSync(
      coordinator: coordinator,
      bridge: bridge,
      clock: clock,
      describe: (bookId) async {
        described.add(bookId);
        return const BookDescription(title: 'A Book', author: 'An Author');
      },
    )..start();
  });

  tearDown(() async {
    await sync.dispose();
    await coordinator.close();
  });

  Future<void> openBook() async {
    await coordinator.open(PlaybackRequest(bookId: 7, timeline: book()));
    await pumpEventQueue();
  }

  Future<void> emit(EngineEvent event) async {
    engine.emit(event);
    await pumpEventQueue();
  }

  test('shows nothing until a book is open', () {
    expect(bridge.updates, isEmpty);
  });

  test('shows the chapter, the book and its author', () async {
    await openBook();
    final shown = bridge.shown;
    expect(shown.title, 'One');
    expect(shown.album, 'A Book');
    expect(shown.artist, 'An Author');
    expect(shown.durationMs, 600 * s);
    expect(shown.positionMs, 0);
    expect(shown.playing, isFalse);
  });

  test('looks each book up once', () async {
    await openBook();
    await coordinator.play();
    await emit(EnginePositionChanged(q(0, 5 * s)));
    expect(described, [7]);
  });

  test('stays quiet while playback advances as the controls expect', () async {
    await openBook();
    await coordinator.play();
    await pumpEventQueue();
    final shown = bridge.updates.length;

    for (var i = 1; i <= 5; i++) {
      clock.advance(const Duration(seconds: 1));
      await emit(EnginePositionChanged(q(0, i * s)));
    }

    expect(bridge.updates, hasLength(shown));
  });

  test('corrects the controls when playback jumps', () async {
    await openBook();
    await coordinator.seekTo(120 * s);
    await pumpEventQueue();
    expect(bridge.shown.positionMs, 120 * s);
  });

  test('names the new chapter when playback reaches it', () async {
    await openBook();
    await coordinator.seekTo(300 * s);
    await pumpEventQueue();
    expect(bridge.shown.title, 'Two');
  });

  test('shows a pause as it happens', () async {
    await openBook();
    await coordinator.play();
    await pumpEventQueue();
    expect(bridge.shown.playing, isTrue);
    await coordinator.pause();
    await pumpEventQueue();
    expect(bridge.shown.playing, isFalse);
  });

  test('removes the controls when the book closes', () async {
    await openBook();
    await coordinator.close();
    await pumpEventQueue();
    expect(bridge.updates.last, isNull);
  });

  group('buttons reach the coordinator', () {
    test('play and pause', () async {
      await openBook();
      await bridge.press(const MediaPlay());
      expect(engine.playing, isTrue);
      await bridge.press(const MediaPause());
      expect(engine.playing, isFalse);
    });

    test('a single play-pause button toggles', () async {
      await openBook();
      await bridge.press(const MediaPlayPause());
      expect(engine.playing, isTrue);
      await bridge.press(const MediaPlayPause());
      expect(engine.playing, isFalse);
    });

    test('skips move by the interval', () async {
      await openBook();
      await bridge.press(const MediaSkipForward());
      expect(engine.lastSeek, q(0, 30 * s));
      await bridge.press(const MediaSkipBackward());
      expect(engine.lastSeek, q(0, 0));
    });

    test('the scrubber and chapter buttons', () async {
      await openBook();
      await bridge.press(const MediaSeek(400 * s));
      expect(engine.lastSeek, q(1, 100 * s));
      await bridge.press(const MediaPreviousChapter());
      expect(engine.lastSeek, q(1, 0));
      await bridge.press(const MediaPreviousChapter());
      expect(engine.lastSeek, q(0, 0));
      await bridge.press(const MediaNextChapter());
      expect(engine.lastSeek, q(1, 0));
    });
  });
}
