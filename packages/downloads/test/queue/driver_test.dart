// The driver, end to end, with a fake store and a fake transport.
//
// This is the first test in which a download goes all the way from queued to completed. It is only
// possible because ADR-0007 kept the queue on our side of the transport line: everything the driver
// touches is an interface or a function, so the whole cycle runs in memory in a millisecond.

import 'dart:async';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_downloads/kikuyomi_downloads.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

/// The queue, in memory: what the Drift store keeps, without the database.
final class FakeDownloadStore implements DownloadStore {
  final tasks = <int, _Task>{};
  final saved = <String>[];

  int add({
    int sourceId = 1,
    int mediaFileId = 100,
    int bookId = 10,
    int priority = 0,
    int attempts = 0,
    DownloadState state = DownloadState.queued,
    DownloadRequest? request,
    DateTime? expiresAt,
  }) {
    final id = tasks.length + 1;
    tasks[id] = _Task(
      taskId: id,
      sourceId: sourceId,
      mediaFileId: mediaFileId,
      bookId: bookId,
      priority: priority,
      attempts: attempts,
      state: state,
      request: request,
      expiresAt: expiresAt,
    );
    return id;
  }

  DownloadState stateOf(int taskId) => tasks[taskId]!.state;

  @override
  Future<List<DownloadCandidate>> readStartable({int limit = 20}) async => [
    for (final task in tasks.values)
      if (task.state == DownloadState.queued ||
          task.state == DownloadState.needsResolve)
        DownloadCandidate(
          taskId: task.taskId,
          sourceId: task.sourceId,
          priority: task.priority,
          askedAt: DateTime.utc(2026),
          bytesTotal: task.bytesTotal,
        ),
  ];

  @override
  Future<Map<int, int>> countRunningBySource() async {
    final counts = <int, int>{};
    for (final task in tasks.values) {
      if (task.state.holdsASlot) {
        counts[task.sourceId] = (counts[task.sourceId] ?? 0) + 1;
      }
    }
    return counts;
  }

  @override
  Future<DownloadSubject?> readSubject(int taskId) async {
    final task = tasks[taskId];
    if (task == null) return null;
    return DownloadSubject(
      taskId: task.taskId,
      mediaFileId: task.mediaFileId,
      bookId: task.bookId,
      state: task.state,
      attempts: task.attempts,
      request: task.request,
      expiresAt: task.expiresAt,
    );
  }

  @override
  Future<void> saveState(
    int taskId,
    DownloadState state, {
    DownloadHold? hold,
  }) async {
    final task = tasks[taskId];
    if (task == null) return;
    task.state = state;
    task.hold = state == DownloadState.waiting ? hold : null;
    saved.add(
      'state $taskId ${state.name}${hold == null ? '' : ' ${hold.name}'}',
    );
  }

  @override
  Future<void> saveResolution(
    int taskId, {
    required DownloadRequest request,
    DateTime? expiresAt,
  }) async {
    tasks[taskId]!
      ..request = request
      ..expiresAt = expiresAt;
    saved.add('resolved $taskId ${request.url}');
  }

  @override
  Future<void> saveProgress(
    int taskId, {
    required int bytesDone,
    int? bytesTotal,
  }) async {
    final task = tasks[taskId]!;
    task.bytesDone = bytesDone;
    if (bytesTotal != null) task.bytesTotal = bytesTotal;
  }

  @override
  Future<void> saveFailure(
    int taskId, {
    required String error,
    required bool permanent,
    DateTime? retryAt,
  }) async {
    final task = tasks[taskId]!;
    task
      ..state = permanent
          ? DownloadState.failedPermanent
          : DownloadState.failedRetryable
      ..attempts = task.attempts + 1
      ..lastError = error
      ..retryAt = retryAt;
    saved.add('failed $taskId permanent=$permanent');
  }

  @override
  Future<void> saveTransportId(int taskId, String? transportTaskId) async {
    tasks[taskId]?.transportId = transportTaskId;
  }

  @override
  Future<void> saveCompleted(int taskId, {required String localPath}) async {
    tasks[taskId]!
      ..state = DownloadState.completed
      ..localPath = localPath;
    saved.add('completed $taskId $localPath');
  }

  @override
  Future<List<int>> readRetryDue(DateTime now) async => [
    for (final task in tasks.values)
      if (task.state == DownloadState.failedRetryable &&
          task.retryAt != null &&
          !task.retryAt!.isAfter(now))
        task.taskId,
  ];
}

final class _Task {
  _Task({
    required this.taskId,
    required this.sourceId,
    required this.mediaFileId,
    required this.bookId,
    required this.priority,
    required this.attempts,
    required this.state,
    this.request,
    this.expiresAt,
  });

  final int taskId;
  final int sourceId;
  final int mediaFileId;
  final int bookId;
  final int priority;
  int attempts;
  DownloadState state;
  DownloadHold? hold;
  DownloadRequest? request;
  DateTime? expiresAt;
  int bytesDone = 0;
  int? bytesTotal;
  String? lastError;
  DateTime? retryAt;
  String? transportId;
  String? localPath;
}

/// A transport that moves no bytes and says whatever a test tells it to.
final class FakeTransport implements DownloadTransport {
  final started = <int>[];
  final paused = <int>[];
  final cancelled = <int>[];
  final names = <int, String>{};
  final requests = <int, DownloadRequest>{};

  /// Thrown by the next [start], then forgotten.
  Object? nextStartFailure;

  final _reports = StreamController<TransportReport>.broadcast();

  @override
  Stream<TransportReport> get reports => _reports.stream;

  @override
  Future<String> start({
    required int taskId,
    required DownloadRequest request,
    required String fileName,
  }) async {
    final failure = nextStartFailure;
    if (failure != null) {
      nextStartFailure = null;
      throw failure;
    }
    started.add(taskId);
    names[taskId] = fileName;
    requests[taskId] = request;
    return 'transport-$taskId';
  }

  @override
  Future<void> pause(int taskId) async => paused.add(taskId);

  @override
  Future<void> cancel(int taskId) async => cancelled.add(taskId);

  /// Says [report] and lets the driver finish acting on it.
  Future<void> say(TransportReport report) async {
    _reports.add(report);
    await pumpEventQueue();
  }

  Future<void> close() => _reports.close();
}

void main() {
  late FakeDownloadStore store;
  late FakeTransport transport;
  late FakeClock clock;
  late DownloadDriver driver;
  late Map<int, ResolvedMedia> resolutions;
  late List<int> resolved;
  Object? resolveFailure;

  DownloadDriver build({
    DownloadLimits limits = const DownloadLimits(),
    DeviceConditions device = (
      network: NetworkKind.unmetered,
      freeSpaceBytes: 50 * 1024 * 1024 * 1024,
    ),
    DownloadPostProcessor? postProcess,
  }) => DownloadDriver(
    store: store,
    transport: transport,
    clock: clock,
    limits: limits,
    postProcess: postProcess,
    conditions: () async => device,
    resolve: (fileId) async {
      resolved.add(fileId);
      final failure = resolveFailure;
      if (failure != null) throw failure;
      return resolutions[fileId] ??
          ResolvedMedia(uri: Uri.parse('https://example.org/$fileId.mp3'));
    },
  );

  setUp(() {
    store = FakeDownloadStore();
    transport = FakeTransport();
    clock = FakeClock(DateTime.utc(2026, 9, 24, 9));
    resolutions = {};
    resolved = [];
    resolveFailure = null;
    driver = build();
    driver.start();
  });

  tearDown(() async {
    await driver.dispose();
    await transport.close();
  });

  group('one file, all the way', () {
    test('queued to completed', () async {
      final task = store.add(mediaFileId: 100, bookId: 10);

      await driver.pump();

      expect(resolved, [100], reason: 'resolved just in time, once');
      expect(transport.started, [task]);
      expect(store.stateOf(task), DownloadState.downloading);
      expect(store.tasks[task]!.transportId, 'transport-$task');

      await transport.say(
        TransportProgress(task, bytesDone: 500, bytesTotal: 1000),
      );
      expect(store.tasks[task]!.bytesDone, 500);
      expect(store.tasks[task]!.bytesTotal, 1000);

      await transport.say(
        TransportFinished(task, path: 'downloads/10_100', bytesTotal: 1000),
      );

      expect(store.stateOf(task), DownloadState.completed);
      expect(store.tasks[task]!.localPath, 'downloads/10_100');
      expect(
        store.tasks[task]!.transportId,
        isNull,
        reason: 'a finished task has no live job for the reconciler to match',
      );
    });

    test('names the file after its book and its file', () async {
      final task = store.add(mediaFileId: 77, bookId: 5);

      await driver.pump();

      expect(transport.names[task], '5_77');
    });

    test('hands the transport the headers the site wants', () async {
      resolutions[100] = ResolvedMedia(
        uri: Uri.parse('https://archive.org/a.mp3'),
        headers: const {'referer': 'https://archive.org/'},
      );
      final task = store.add(mediaFileId: 100);

      await driver.pump();

      expect(
        transport.requests[task]!.headers['referer'],
        'https://archive.org/',
      );
    });

    test(
      'passes the file through the post-processor before finishing',
      () async {
        driver = build(
          postProcess: (subject, path) async =>
              'books/${subject.bookId}/final.mp3',
        )..start();
        final task = store.add();

        await driver.pump();
        await transport.say(TransportFinished(task, path: 'tmp/raw'));

        expect(store.tasks[task]!.localPath, 'books/10/final.mp3');
      },
    );

    test('a file the post-processor refuses fails for good', () async {
      // A file that arrived but is not what it claimed to be will not become one by being fetched
      // again from the same place.
      driver = build(
        postProcess: (subject, path) async =>
            throw StateError('that is an HTML error page'),
      )..start();
      final task = store.add();

      await driver.pump();
      await transport.say(TransportFinished(task, path: 'tmp/raw'));

      expect(store.stateOf(task), DownloadState.failedPermanent);
    });
  });

  group('resolution (§5.4)', () {
    test('reuses an address that has not expired', () async {
      store.add(
        request: const DownloadRequest(url: 'https://example.org/kept.mp3'),
        expiresAt: clock.now().add(const Duration(minutes: 10)),
      );

      await driver.pump();

      expect(resolved, isEmpty, reason: 'the source is not asked again');
    });

    test('asks again once the address has expired', () async {
      store.add(
        request: const DownloadRequest(url: 'https://example.org/stale.mp3'),
        expiresAt: clock.now().subtract(const Duration(minutes: 1)),
      );

      await driver.pump();

      expect(resolved, hasLength(1));
    });

    test(
      'a rejected URL goes back to be resolved, costing no attempt',
      () async {
        final task = store.add();
        await driver.pump();

        await transport.say(
          TransportFailed(task, message: '403', urlRejected: true),
        );

        expect(store.stateOf(task), DownloadState.needsResolve);
        expect(
          store.tasks[task]!.attempts,
          0,
          reason: 'an address expiring is the source working as designed',
        );

        // And the next pass asks the extension again.
        await driver.pump();
        expect(resolved, hasLength(2));
      },
    );

    test('a resolution that fails is a retryable failure', () async {
      resolveFailure = StateError('the source would not answer');
      final task = store.add();

      await driver.pump();

      expect(store.stateOf(task), DownloadState.failedRetryable);
      expect(transport.started, isEmpty);
    });
  });

  group('failure and retry (§5.5)', () {
    test('waits, then rejoins the queue when the wait is over', () async {
      final task = store.add();
      await driver.pump();

      await transport.say(
        TransportFailed(task, message: 'the connection went'),
      );

      expect(store.stateOf(task), DownloadState.failedRetryable);
      expect(store.tasks[task]!.attempts, 1);
      expect(store.tasks[task]!.retryAt, isNotNull);

      // Too soon: nothing moves.
      await driver.pump();
      expect(store.stateOf(task), DownloadState.failedRetryable);

      clock.advance(const Duration(minutes: 5));
      await driver.pump();
      expect(transport.started, [task, task]);
    });

    test('gives up after five attempts', () async {
      final task = store.add(attempts: 4);
      await driver.pump();

      await transport.say(TransportFailed(task, message: 'again'));

      expect(store.stateOf(task), DownloadState.failedPermanent);
      expect(store.tasks[task]!.retryAt, isNull);
    });

    test('a permanent failure never waits', () async {
      final task = store.add();
      await driver.pump();

      await transport.say(
        TransportFailed(task, message: 'gone', permanent: true),
      );

      expect(store.stateOf(task), DownloadState.failedPermanent);
      expect(store.tasks[task]!.retryAt, isNull);
    });

    test('a transport that will not start is a failure', () async {
      transport.nextStartFailure = StateError('no room');
      final task = store.add();

      await driver.pump();

      expect(store.stateOf(task), DownloadState.failedRetryable);
    });
  });

  group('the policy is obeyed', () {
    test('holds what it cannot start, with the reason', () async {
      for (var i = 0; i < 5; i++) {
        store.add(sourceId: i, mediaFileId: 100 + i);
      }

      await driver.pump();

      expect(transport.started, hasLength(3));
      final held = store.tasks.values.where(
        (t) => t.state == DownloadState.waiting,
      );
      expect(held, hasLength(2));
      expect(held.every((t) => t.hold == DownloadHold.slot), isTrue);
    });

    test('holds everything, and resolves nothing, with no network', () async {
      store.add();
      driver = build(
        device: (network: NetworkKind.none, freeSpaceBytes: 999999999999),
      )..start();

      await driver.pump();

      expect(transport.started, isEmpty);
      expect(
        resolved,
        isEmpty,
        reason:
            'asking a source for an address it cannot be fetched from is waste',
      );
      expect(store.tasks[1]!.hold, DownloadHold.network);
    });
  });

  group('a report that no longer applies (§5.3)', () {
    test('a completion after a cancel does nothing', () async {
      final task = store.add();
      await driver.pump();
      await driver.cancel(task);

      await transport.say(TransportFinished(task, path: 'tmp/raw'));

      expect(store.stateOf(task), DownloadState.cancelled);
      expect(transport.cancelled, [task]);
    });

    test('progress after a cancel does nothing', () async {
      final task = store.add();
      await driver.pump();
      await driver.cancel(task);

      await transport.say(TransportProgress(task, bytesDone: 900));

      expect(store.tasks[task]!.bytesDone, 0);
    });

    test('a failure after a completion does nothing', () async {
      final task = store.add();
      await driver.pump();
      await transport.say(TransportFinished(task, path: 'downloads/a'));

      await transport.say(TransportFailed(task, message: 'too late'));

      expect(store.stateOf(task), DownloadState.completed);
    });
  });

  group('the listener interrupting', () {
    test('pausing tells the transport and stops the task', () async {
      final task = store.add();
      await driver.pump();

      await driver.pause(task);

      expect(transport.paused, [task]);
      expect(store.stateOf(task), DownloadState.paused);
    });

    test('a paused task is not picked up again until it is resumed', () async {
      final task = store.add();
      await driver.pump();
      await driver.pause(task);

      await driver.pump();

      expect(transport.started, [task], reason: 'started once, not twice');
    });
  });

  test('a pass with nothing to do costs nothing', () async {
    await driver.pump();

    expect(transport.started, isEmpty);
    expect(store.saved, isEmpty);
  });

  test('nothing is acted on before start()', () async {
    // The driver from setUp is listening to the same transport, so it has to go first or it would
    // answer the report this test means for the quiet one.
    await driver.dispose();
    final quiet = build();
    final task = store.add();
    await quiet.pump();

    await transport.say(TransportFinished(task, path: 'downloads/a'));

    expect(store.stateOf(task), DownloadState.downloading);
    await quiet.dispose();
  });
}
