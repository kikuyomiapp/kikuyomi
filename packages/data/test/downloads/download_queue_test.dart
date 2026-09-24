// Putting files into the download queue (§5.2).
//
// The rules worth pinning are all about *not* queueing: a file already on the device, a file already
// asked for, and a file two chapters share. The last is the one the design cares most about — a
// thirty-chapter M4B must be fetched once — and it is enforced by the unique key rather than by the
// caller remembering.

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

  setUp(() async {
    db = KikuyomiDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    clock = FakeClock(DateTime.utc(2026, 9, 24, 9));
    await db
        .into(db.sources)
        .insert(
          const SourcesCompanion(
            id: Value(7),
            key: Value('librivox'),
            name: Value('LibriVox'),
            lang: Value('multi'),
          ),
        );
  });

  Future<int> addBook({String key = 'a-book'}) => db
      .into(db.books)
      .insert(
        BooksCompanion.insert(
          sourceId: 7,
          key: key,
          title: 'A Book',
          createdAt: clock.now(),
          updatedAt: clock.now(),
        ),
      );

  Future<int> addFile(
    int bookId, {
    required String fileKey,
    String? localPath,
  }) => db
      .into(db.mediaFiles)
      .insert(
        MediaFilesCompanion.insert(
          bookId: bookId,
          fileKey: fileKey,
          localPath: Value(localPath),
        ),
      );

  /// A chapter whose layout names [files], in order.
  Future<int> addChapter(
    int bookId, {
    required String key,
    required List<int> files,
    int sourceIndex = 0,
  }) async {
    final chapter = await db
        .into(db.chapters)
        .insert(
          ChaptersCompanion.insert(
            bookId: bookId,
            key: key,
            title: key,
            sourceIndex: sourceIndex,
            createdAt: clock.now(),
            updatedAt: clock.now(),
          ),
        );
    for (final (ordinal, file) in files.indexed) {
      await db
          .into(db.chapterSegments)
          .insert(
            ChapterSegmentsCompanion.insert(
              chapterId: chapter,
              ordinal: ordinal,
              mediaFileId: file,
            ),
          );
    }
    return chapter;
  }

  Future<List<DownloadTaskRow>> tasks() => db.select(db.downloadTasks).get();

  group('queueing a book', () {
    test('queues every file it does not already have', () async {
      final book = await addBook();
      await addFile(book, fileKey: 'one.mp3');
      await addFile(book, fileKey: 'two.mp3');

      final asked = await enqueueBookDownload(db, book, clock: clock);

      expect(asked.added, 2);
      expect(asked.alreadyOnDevice, 0);
      expect(await tasks(), hasLength(2));
      expect(
        (await tasks()).every((t) => t.state == DownloadState.queued),
        isTrue,
      );
    });

    test('leaves a task with no address at all (§5.4)', () async {
      // Resolution is just in time, as a file is about to start. Enqueueing a hundred-chapter book
      // must not cost a hundred calls to its source.
      final book = await addBook();
      await addFile(book, fileKey: 'one.mp3');

      await enqueueBookDownload(db, book, clock: clock);

      final task = (await tasks()).single;
      expect(task.requestSnapshot, isNull);
      expect(task.expiresAt, isNull);
      expect(task.attempts, 0);
    });

    test('queues nothing for a book that is already on the device', () async {
      // A local book's files have a path from the moment it was imported.
      final book = await addBook(key: 'local');
      await addFile(book, fileKey: '1.mp3', localPath: 'C:/Books/1.mp3');
      await addFile(book, fileKey: '2.mp3', localPath: 'C:/Books/2.mp3');

      final asked = await enqueueBookDownload(db, book, clock: clock);

      expect(asked.added, 0);
      expect(asked.alreadyOnDevice, 2);
      expect(asked.isEmpty, isTrue);
      expect(await tasks(), isEmpty);
    });

    test('asking twice does not queue anything twice', () async {
      final book = await addBook();
      await addFile(book, fileKey: 'one.mp3');

      await enqueueBookDownload(db, book, clock: clock);
      final again = await enqueueBookDownload(db, book, clock: clock);

      expect(again.added, 0);
      expect(again.alreadyQueued, 1);
      expect(await tasks(), hasLength(1));
    });

    test('a file already downloaded is not fetched again', () async {
      final book = await addBook();
      final file = await addFile(book, fileKey: 'one.mp3');
      await enqueueBookDownload(db, book, clock: clock);
      await (db.update(
        db.downloadTasks,
      )..where((t) => t.mediaFileId.equals(file))).write(
        const DownloadTasksCompanion(state: Value(DownloadState.completed)),
      );

      final again = await enqueueBookDownload(db, book, clock: clock);

      expect(again.alreadyOnDevice, 1);
      expect(again.added, 0);
      expect((await tasks()).single.state, DownloadState.completed);
    });
  });

  group('asking again for one that stopped', () {
    for (final stopped in [
      DownloadState.cancelled,
      DownloadState.failedPermanent,
      DownloadState.failedRetryable,
    ]) {
      test(
        'revives a ${stopped.name} task, and forgets its attempts',
        () async {
          final book = await addBook();
          final file = await addFile(book, fileKey: 'one.mp3');
          await enqueueBookDownload(db, book, clock: clock);
          await (db.update(
            db.downloadTasks,
          )..where((t) => t.mediaFileId.equals(file))).write(
            DownloadTasksCompanion(
              state: Value(stopped),
              attempts: const Value(5),
              lastError: const Value('it went wrong'),
              hold: const Value(DownloadHold.network),
              retryAt: Value(clock.now()),
            ),
          );

          final again = await enqueueBookDownload(db, book, clock: clock);

          expect(
            again.added,
            1,
            reason: 'asking again is how a listener retries',
          );
          final task = (await tasks()).single;
          expect(task.state, DownloadState.queued);
          expect(task.attempts, 0);
          expect(task.lastError, isNull);
          expect(task.hold, isNull);
          expect(task.retryAt, isNull);
        },
      );
    }

    test('leaves one that is still going where it is', () async {
      final book = await addBook();
      final file = await addFile(book, fileKey: 'one.mp3');
      await enqueueBookDownload(db, book, clock: clock);
      await (db.update(
        db.downloadTasks,
      )..where((t) => t.mediaFileId.equals(file))).write(
        const DownloadTasksCompanion(
          state: Value(DownloadState.downloading),
          bytesDone: Value(4096),
        ),
      );

      final again = await enqueueBookDownload(db, book, clock: clock);

      expect(again.alreadyQueued, 1);
      final task = (await tasks()).single;
      expect(task.state, DownloadState.downloading);
      expect(task.bytesDone, 4096, reason: 'its progress is not thrown away');
    });
  });

  group('queueing a chapter', () {
    test('queues the files its segments name, in order', () async {
      final book = await addBook();
      final first = await addFile(book, fileKey: 'part1.mp3');
      final second = await addFile(book, fileKey: 'part2.mp3');
      await addFile(book, fileKey: 'elsewhere.mp3');
      final chapter = await addChapter(
        book,
        key: 'ch-1',
        files: [first, second],
      );

      final asked = await enqueueChapterDownload(db, chapter, clock: clock);

      expect(asked.added, 2);
      expect(
        {for (final task in await tasks()) task.mediaFileId},
        {first, second},
        reason: 'the file no segment names is not fetched',
      );
    });

    test(
      'a shared file is queued once, however many chapters want it',
      () async {
        // The M4B case §5.2 exists for: thirty chapters, one file, one fetch.
        final book = await addBook();
        final whole = await addFile(book, fileKey: 'whole.m4b');
        final first = await addChapter(book, key: 'ch-1', files: [whole]);
        final second = await addChapter(
          book,
          key: 'ch-2',
          files: [whole],
          sourceIndex: 1,
        );

        final one = await enqueueChapterDownload(db, first, clock: clock);
        final two = await enqueueChapterDownload(db, second, clock: clock);

        expect(one.added, 1);
        expect(two.added, 0);
        expect(two.alreadyQueued, 1);
        expect(await tasks(), hasLength(1));
      },
    );

    test('a chapter naming one file twice queues it once', () async {
      final book = await addBook();
      final whole = await addFile(book, fileKey: 'whole.m4b');
      final chapter = await addChapter(
        book,
        key: 'ch-1',
        files: [whole, whole],
      );

      final asked = await enqueueChapterDownload(db, chapter, clock: clock);

      expect(asked.added, 1);
      expect(await tasks(), hasLength(1));
    });
  });

  group('priority', () {
    test('raises a task already queued, and never lowers one', () async {
      final book = await addBook();
      await addFile(book, fileKey: 'one.mp3');
      await enqueueBookDownload(db, book, clock: clock, priority: 5);

      await enqueueBookDownload(db, book, clock: clock, priority: 10);
      expect((await tasks()).single.priority, 10);

      await enqueueBookDownload(db, book, clock: clock, priority: 1);
      expect(
        (await tasks()).single.priority,
        10,
        reason: 'the chapter about to be played stays above the rest',
      );
    });
  });

  group('what the scheduler may start', () {
    test('is what waits on the app, not on the world', () async {
      final book = await addBook();
      final states = {
        DownloadState.queued: 'a.mp3',
        DownloadState.needsResolve: 'b.mp3',
        DownloadState.waiting: 'c.mp3',
        DownloadState.downloading: 'd.mp3',
        DownloadState.completed: 'e.mp3',
        DownloadState.failedPermanent: 'f.mp3',
      };
      for (final entry in states.entries) {
        final file = await addFile(book, fileKey: entry.value);
        await db
            .into(db.downloadTasks)
            .insert(
              DownloadTasksCompanion.insert(
                mediaFileId: file,
                state: entry.key,
                createdAt: clock.now(),
                updatedAt: clock.now(),
              ),
            );
      }

      final startable = await readStartableDownloads(db);

      expect(
        {for (final task in startable) task.state},
        {DownloadState.queued, DownloadState.needsResolve},
      );
    });

    test('is ordered by priority, then by when it was asked for', () async {
      final book = await addBook();
      final first = await addFile(book, fileKey: 'first.mp3');
      clock.advance(const Duration(minutes: 1));
      final second = await addFile(book, fileKey: 'second.mp3');
      final urgent = await addFile(book, fileKey: 'urgent.mp3');

      await enqueueChapterDownload(
        db,
        await addChapter(book, key: 'one', files: [first]),
        clock: clock,
      );
      clock.advance(const Duration(minutes: 1));
      await enqueueChapterDownload(
        db,
        await addChapter(book, key: 'two', files: [second], sourceIndex: 1),
        clock: clock,
      );
      await enqueueChapterDownload(
        db,
        await addChapter(book, key: 'now', files: [urgent], sourceIndex: 2),
        clock: clock,
        priority: 10,
      );

      expect(
        [for (final task in await readStartableDownloads(db)) task.mediaFileId],
        [urgent, first, second],
      );
    });
  });

  test('a book shows only its own downloads', () async {
    final mine = await addBook(key: 'mine');
    final other = await addBook(key: 'other');
    await addFile(mine, fileKey: 'mine.mp3');
    await addFile(other, fileKey: 'other.mp3');
    await enqueueBookDownload(db, mine, clock: clock);
    await enqueueBookDownload(db, other, clock: clock);

    expect(await watchBookDownloads(db, mine).first, hasLength(1));
    expect(await watchDownloadQueue(db).first, hasLength(2));
  });

  test('a file that goes takes its task with it', () async {
    // Cascading: a file no longer part of any book has nothing to download.
    final book = await addBook();
    final file = await addFile(book, fileKey: 'one.mp3');
    await enqueueBookDownload(db, book, clock: clock);

    await (db.delete(db.mediaFiles)..where((f) => f.id.equals(file))).go();

    expect(await tasks(), isEmpty);
  });
}
