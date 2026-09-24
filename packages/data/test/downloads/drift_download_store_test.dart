// The download queue over a real database, through the interface the driver sees.
//
// The joins are the part worth testing: a task names a file, a file belongs to a book, and a book
// came from a source, so the per-source cap the scheduler applies is two joins from the row it is
// counting. Getting that wrong would cap the wrong thing and nothing would look broken.

// Drift exports a query helper called isNull that collides with the matcher of the same name.
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

void main() {
  late KikuyomiDatabase db;
  late FakeClock clock;
  late DriftDownloadStore store;

  setUp(() async {
    db = KikuyomiDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    clock = FakeClock(DateTime.utc(2026, 9, 24, 9));
    store = DriftDownloadStore(db, clock: clock);
  });

  Future<void> addSource(int id) => db
      .into(db.sources)
      .insert(
        SourcesCompanion(
          id: Value(id),
          key: Value('s$id'),
          name: Value('Source $id'),
          lang: const Value('en'),
        ),
      );

  Future<int> addBook(int sourceId, {String key = 'a-book'}) => db
      .into(db.books)
      .insert(
        BooksCompanion.insert(
          sourceId: sourceId,
          key: key,
          title: 'A Book',
          createdAt: clock.now(),
          updatedAt: clock.now(),
        ),
      );

  Future<int> addFile(int bookId, {String fileKey = 'one.mp3'}) => db
      .into(db.mediaFiles)
      .insert(MediaFilesCompanion.insert(bookId: bookId, fileKey: fileKey));

  Future<int> addTask(
    int fileId, {
    DownloadState state = DownloadState.queued,
    int priority = 0,
    int attempts = 0,
  }) => db
      .into(db.downloadTasks)
      .insert(
        DownloadTasksCompanion.insert(
          mediaFileId: fileId,
          state: state,
          priority: Value(priority),
          attempts: Value(attempts),
          createdAt: clock.now(),
          updatedAt: clock.now(),
        ),
      );

  Future<DownloadTaskRow> taskRow(int id) =>
      (db.select(db.downloadTasks)..where((t) => t.id.equals(id))).getSingle();

  /// A source, a book and a file, ready for a task.
  Future<int> aFile({int sourceId = 7, String fileKey = 'one.mp3'}) async {
    await addSource(sourceId);
    return addFile(await addBook(sourceId), fileKey: fileKey);
  }

  group('what can start', () {
    test('carries the source two joins away', () async {
      final file = await aFile(sourceId: 42);
      final task = await addTask(file, priority: 3);

      final startable = await store.readStartable();

      expect(startable, hasLength(1));
      expect(startable.single.taskId, task);
      expect(
        startable.single.sourceId,
        42,
        reason: 'the cap is a promise to the site, so it must be the site id',
      );
      expect(startable.single.priority, 3);
    });

    test('is everything pending, held or not', () async {
      await addSource(1);
      final book = await addBook(1);
      final tasks = <int, DownloadState>{};
      for (final state in DownloadState.values) {
        tasks[await addTask(
              await addFile(book, fileKey: '${state.name}.mp3'),
              state: state,
            )] =
            state;
      }

      final startable = await store.readStartable();

      expect(
        {for (final task in startable) tasks[task.taskId]},
        {
          DownloadState.queued,
          DownloadState.needsResolve,
          // A held task belongs here: the scheduler is the only thing that can release one, and it
          // cannot release what it cannot see.
          DownloadState.waiting,
        },
      );
    });

    test('is ordered by priority, then age, then id', () async {
      await addSource(1);
      final book = await addBook(1);
      final first = await addTask(await addFile(book, fileKey: 'a.mp3'));
      final urgent = await addTask(
        await addFile(book, fileKey: 'b.mp3'),
        priority: 9,
      );
      clock.advance(const Duration(minutes: 5));
      final later = await addTask(await addFile(book, fileKey: 'c.mp3'));

      expect(
        [for (final task in await store.readStartable()) task.taskId],
        [urgent, first, later],
      );
    });

    test('takes no more than it was asked for', () async {
      await addSource(1);
      final book = await addBook(1);
      for (var i = 0; i < 5; i++) {
        await addTask(await addFile(book, fileKey: '$i.mp3'));
      }

      expect(await store.readStartable(limit: 2), hasLength(2));
    });
  });

  group('what is running', () {
    test('is counted by source, not by book', () async {
      await addSource(1);
      await addSource(2);
      final oneBook = await addBook(1, key: 'one');
      final otherBook = await addBook(1, key: 'two');
      final elsewhere = await addBook(2, key: 'three');
      await addTask(await addFile(oneBook), state: DownloadState.downloading);
      await addTask(await addFile(otherBook), state: DownloadState.resolving);
      await addTask(await addFile(elsewhere), state: DownloadState.processing);

      expect(await store.countRunningBySource(), {1: 2, 2: 1});
    });

    test('counts nothing that is merely waiting', () async {
      final file = await aFile();
      await addTask(file, state: DownloadState.waiting);

      expect(await store.countRunningBySource(), isEmpty);
    });

    test(
      'is listed for the reconciler, with the transport it was given to',
      () async {
        await addSource(1);
        final book = await addBook(1);
        final moving = await addTask(
          await addFile(book, fileKey: 'a.mp3'),
          state: DownloadState.downloading,
        );
        await store.saveTransportId(moving, 'platform-job-7');
        await addTask(
          await addFile(book, fileKey: 'b.mp3'),
          state: DownloadState.queued,
        );

        final inFlight = await store.readInFlight();

        expect(inFlight, hasLength(1));
        expect(inFlight.single.taskId, moving);
        expect(inFlight.single.state, DownloadState.downloading);
        expect(inFlight.single.transportTaskId, 'platform-job-7');
      },
    );
  });

  group('the subject of a task', () {
    test('names its file and its book', () async {
      await addSource(7);
      final book = await addBook(7);
      final file = await addFile(book);
      final task = await addTask(file);

      final subject = await store.readSubject(task);

      expect(subject!.mediaFileId, file);
      expect(subject.bookId, book);
      expect(subject.request, isNull);
    });

    test('is null for a task that has gone', () async {
      expect(await store.readSubject(999), isNull);
    });

    group('knows whether its address is still usable', () {
      test('not when there is none', () async {
        final task = await addTask(await aFile());
        final subject = await store.readSubject(task);

        expect(subject!.hasUsableRequest(clock.now()), isFalse);
      });

      test('yes when the source gave no expiry', () async {
        final task = await addTask(await aFile());
        await store.saveResolution(
          task,
          request: const DownloadRequest(url: 'https://example.org/a.mp3'),
        );

        final subject = await store.readSubject(task);
        expect(subject!.hasUsableRequest(clock.now()), isTrue);
      });

      test('no once its expiry has passed (§5.4)', () async {
        final task = await addTask(await aFile());
        await store.saveResolution(
          task,
          request: const DownloadRequest(url: 'https://example.org/a.mp3'),
          expiresAt: clock.now().add(const Duration(minutes: 5)),
        );

        final subject = await store.readSubject(task);
        expect(subject!.hasUsableRequest(clock.now()), isTrue);
        expect(
          subject.hasUsableRequest(clock.now().add(const Duration(hours: 1))),
          isFalse,
        );
      });
    });
  });

  group('writing what the driver learns', () {
    test('a state, with the reason it waits', () async {
      final task = await addTask(await aFile());

      await store.saveState(
        task,
        DownloadState.waiting,
        hold: DownloadHold.network,
      );

      final row = await taskRow(task);
      expect(row.state, DownloadState.waiting);
      expect(row.hold, DownloadHold.network);
    });

    test('and forgets the reason once it stops waiting', () async {
      // A task that is moving must not go on claiming it wants Wi-Fi.
      final task = await addTask(await aFile());
      await store.saveState(
        task,
        DownloadState.waiting,
        hold: DownloadHold.network,
      );

      await store.saveState(task, DownloadState.downloading);

      expect((await taskRow(task)).hold, isNull);
    });

    test('and writes nothing at all when neither has changed', () async {
      // The scheduler reconsiders every held task on every pass, so re-recording the same hold is the
      // ordinary case. Writing the row again would be a change notification to every screen watching
      // the queue, for no change.
      final task = await addTask(await aFile());
      await store.saveState(
        task,
        DownloadState.waiting,
        hold: DownloadHold.slot,
      );
      final before = (await taskRow(task)).updatedAt;
      clock.advance(const Duration(minutes: 1));

      await store.saveState(
        task,
        DownloadState.waiting,
        hold: DownloadHold.slot,
      );

      expect((await taskRow(task)).updatedAt, before);
    });

    test('but does write when only the reason has changed', () async {
      final task = await addTask(await aFile());
      await store.saveState(
        task,
        DownloadState.waiting,
        hold: DownloadHold.slot,
      );

      await store.saveState(
        task,
        DownloadState.waiting,
        hold: DownloadHold.network,
      );

      expect((await taskRow(task)).hold, DownloadHold.network);
    });

    test('an address, with its expiry', () async {
      final task = await addTask(await aFile());
      final expires = clock.now().add(const Duration(minutes: 10));

      await store.saveResolution(
        task,
        request: const DownloadRequest(
          url: 'https://archive.org/a.mp3',
          headers: {'referer': 'https://archive.org/'},
        ),
        expiresAt: expires,
      );

      final row = await taskRow(task);
      expect(row.requestSnapshot!.url, 'https://archive.org/a.mp3');
      expect(row.requestSnapshot!.headers['referer'], 'https://archive.org/');
      expect(row.expiresAt, expires);
    });

    test('progress, and a total only once the site has said', () async {
      final task = await addTask(await aFile());

      await store.saveProgress(task, bytesDone: 100);
      expect((await taskRow(task)).bytesTotal, isNull);

      await store.saveProgress(task, bytesDone: 200, bytesTotal: 5000);
      expect((await taskRow(task)).bytesDone, 200);
      expect((await taskRow(task)).bytesTotal, 5000);

      // A later report without a total does not throw the known one away.
      await store.saveProgress(task, bytesDone: 300);
      expect((await taskRow(task)).bytesTotal, 5000);
    });

    test('a failure, counting the attempt', () async {
      final task = await addTask(await aFile(), attempts: 2);
      final retry = clock.now().add(const Duration(seconds: 20));

      await store.saveFailure(
        task,
        error: 'the connection went',
        permanent: false,
        retryAt: retry,
      );

      final row = await taskRow(task);
      expect(row.state, DownloadState.failedRetryable);
      expect(row.attempts, 3);
      expect(row.lastError, 'the connection went');
      expect(row.retryAt, retry);
    });

    test('a permanent failure keeps no retry', () async {
      final task = await addTask(await aFile());

      await store.saveFailure(task, error: 'gone', permanent: true);

      final row = await taskRow(task);
      expect(row.state, DownloadState.failedPermanent);
      expect(row.retryAt, isNull);
    });

    test('what the transport calls it', () async {
      final task = await addTask(await aFile());

      await store.saveTransportId(task, 'transport-7');
      expect((await taskRow(task)).transportTaskId, 'transport-7');

      await store.saveTransportId(task, null);
      expect((await taskRow(task)).transportTaskId, isNull);
    });
  });

  group('finishing', () {
    test('writes the file and the task together (§5.7)', () async {
      // Nothing that reads both may see a finished download whose file is not there.
      await addSource(7);
      final book = await addBook(7);
      final file = await addFile(book);
      final task = await addTask(file, state: DownloadState.processing);

      await store.saveCompleted(task, localPath: 'downloads/7/one.mp3');

      final row = await taskRow(task);
      expect(row.state, DownloadState.completed);
      final media = await (db.select(
        db.mediaFiles,
      )..where((f) => f.id.equals(file))).getSingle();
      expect(media.localPath, 'downloads/7/one.mp3');
      expect(media.downloadedAt, clock.now());
    });

    test('clears what a previous failure left behind', () async {
      final task = await addTask(await aFile());
      await store.saveFailure(
        task,
        error: 'it went wrong',
        permanent: false,
        retryAt: clock.now(),
      );

      await store.saveCompleted(task, localPath: 'downloads/a.mp3');

      final row = await taskRow(task);
      expect(row.lastError, isNull);
      expect(row.retryAt, isNull);
    });

    test('a task that has gone is not an error', () async {
      await expectLater(
        store.saveCompleted(999, localPath: 'nowhere'),
        completes,
      );
    });
  });

  group('retries that are due (§5.5)', () {
    test('are the ones whose wait has elapsed', () async {
      await addSource(1);
      final book = await addBook(1);
      final soon = await addTask(
        await addFile(book, fileKey: 'a.mp3'),
        state: DownloadState.failedRetryable,
      );
      final later = await addTask(
        await addFile(book, fileKey: 'b.mp3'),
        state: DownloadState.failedRetryable,
      );
      await store.saveFailure(
        soon,
        error: 'x',
        permanent: false,
        retryAt: clock.now().add(const Duration(seconds: 5)),
      );
      await store.saveFailure(
        later,
        error: 'x',
        permanent: false,
        retryAt: clock.now().add(const Duration(hours: 1)),
      );

      expect(await store.readRetryDue(clock.now()), isEmpty);
      expect(
        await store.readRetryDue(clock.now().add(const Duration(minutes: 1))),
        [soon],
      );
    });

    test('never include a permanent failure', () async {
      final task = await addTask(await aFile());
      await store.saveFailure(task, error: 'gone', permanent: true);

      expect(
        await store.readRetryDue(clock.now().add(const Duration(days: 1))),
        isEmpty,
      );
    });
  });
}
