// What is on the device, and letting go of it, against a real database.
//
// The property worth most here is a refusal: deleting a download must never touch a file the listener
// imported. Their `local_path` points at their own file, wherever they keep it, and the delete path
// runs a real `File.delete` at the end of it — so a confusion between the two would not merely lose a
// row, it would destroy something the app never created.

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

  setUp(() {
    db = KikuyomiDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    clock = FakeClock(DateTime.utc(2026, 9, 24, 9));
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

  Future<int> addBook(String title, {int sourceId = 1, String? key}) => db
      .into(db.books)
      .insert(
        BooksCompanion.insert(
          sourceId: sourceId,
          key: key ?? title,
          title: title,
          createdAt: clock.now(),
          updatedAt: clock.now(),
        ),
      );

  /// A file, optionally already on the device — as a download left it, or as an import did.
  Future<int> addFile(
    int bookId, {
    String fileKey = 'one.mp3',
    String? downloadedTo,
    String? importedFrom,
    int? sizeBytes,
  }) => db
      .into(db.mediaFiles)
      .insert(
        MediaFilesCompanion.insert(
          bookId: bookId,
          fileKey: fileKey,
          sizeBytes: Value(sizeBytes),
          localPath: Value(downloadedTo ?? importedFrom),
          // The one column that separates the two, and the one the delete path checks.
          downloadedAt: Value(downloadedTo == null ? null : clock.now()),
        ),
      );

  Future<int> addTask(
    int fileId, {
    DownloadState state = DownloadState.queued,
    int? bytesTotal,
    int attempts = 0,
  }) => db
      .into(db.downloadTasks)
      .insert(
        DownloadTasksCompanion.insert(
          mediaFileId: fileId,
          state: state,
          bytesTotal: Value(bytesTotal),
          attempts: Value(attempts),
          createdAt: clock.now(),
          updatedAt: clock.now(),
        ),
      );

  Future<MediaFileRow> fileRow(int id) =>
      (db.select(db.mediaFiles)..where((f) => f.id.equals(id))).getSingle();

  group('what the screen lists', () {
    test('carries the book, the file and whether it is really here', () async {
      await addSource(1);
      final book = await addBook('Moby-Dick');
      final here = await addFile(
        book,
        fileKey: 'ch1.mp3',
        downloadedTo: '1/1.mp3',
      );
      final coming = await addFile(book, fileKey: 'ch2.mp3');
      await addTask(here, state: DownloadState.completed, bytesTotal: 600);
      await addTask(coming, state: DownloadState.downloading);

      final entries = await watchDownloads(db).first;

      expect(entries, hasLength(2));
      expect(entries.first.bookTitle, 'Moby-Dick');
      expect(entries.first.fileKey, 'ch1.mp3');
      expect(entries.first.isOnDevice, isTrue);
      expect(entries.first.sizeBytes, 600);
      expect(entries.last.isOnDevice, isFalse);
    });

    test('an imported file is not the download system to speak for', () async {
      // It is on the device and it has a path, and neither is this screen's business.
      await addSource(1);
      final book = await addBook('A Local Book');
      final file = await addFile(book, importedFrom: r'D:\Books\local.m4b');
      await addTask(file, state: DownloadState.completed);

      expect((await watchDownloads(db).first).single.isOnDevice, isFalse);
    });

    test(
      'prefers the size the site gave to the one the source declared',
      () async {
        await addSource(1);
        final book = await addBook('A Book');
        final file = await addFile(book, sizeBytes: 100);
        await addTask(file, bytesTotal: 999);

        expect((await watchDownloads(db).first).single.sizeBytes, 999);
      },
    );

    test('falls back to the declared size, and then to nothing', () async {
      await addSource(1);
      final book = await addBook('A Book');
      await addTask(await addFile(book, fileKey: 'a.mp3', sizeBytes: 100));
      await addTask(await addFile(book, fileKey: 'b.mp3'));

      final entries = await watchDownloads(db).first;
      expect(entries.first.sizeBytes, 100);
      expect(entries.last.sizeBytes, isNull);
    });

    test('is ordered by book, then by file', () async {
      await addSource(1);
      final second = await addBook('Zoology');
      final first = await addBook('Anatomy');
      await addTask(await addFile(second, fileKey: 'z1.mp3'));
      await addTask(await addFile(first, fileKey: 'a1.mp3'));
      await addTask(await addFile(first, fileKey: 'a2.mp3'));

      expect(
        [for (final e in await watchDownloads(db).first) e.fileKey],
        ['a1.mp3', 'a2.mp3', 'z1.mp3'],
      );
    });

    test('a file with no task is not in it', () async {
      // The row is what "asked for" means, so deleting a download removes it from the screen.
      await addSource(1);
      await addFile(await addBook('A Book'));

      expect(await watchDownloads(db).first, isEmpty);
    });
  });

  group('the total (§5.6)', () {
    test('counts what is downloaded and nothing else', () async {
      await addSource(1);
      final book = await addBook('A Book');
      await addTask(
        await addFile(book, fileKey: 'a.mp3', downloadedTo: '1/1.mp3'),
        bytesTotal: 500,
      );
      await addTask(
        await addFile(book, fileKey: 'b.mp3', downloadedTo: '1/2.mp3'),
        bytesTotal: 300,
      );
      // Asked for, not here yet.
      await addTask(await addFile(book, fileKey: 'c.mp3'), bytesTotal: 900);
      // The listener's own file.
      await addTask(
        await addFile(book, fileKey: 'd.mp3', importedFrom: r'D:\d.m4b'),
        bytesTotal: 7000,
      );

      expect(await downloadedBytes(db), 800);
    });

    test('a file whose size nothing stated counts as nothing', () async {
      await addSource(1);
      final book = await addBook('A Book');
      await addTask(await addFile(book, downloadedTo: '1/1.mp3'));

      expect(await downloadedBytes(db), 0);
    });

    test('nothing downloaded is nought rather than an error', () async {
      expect(await downloadedBytes(db), 0);
    });
  });

  group('which file a row is responsible for', () {
    test('is the downloaded one', () async {
      await addSource(1);
      final file = await addFile(
        await addBook('A Book'),
        downloadedTo: '12/159.mp3',
      );

      expect(await readDownloadedPath(db, file), '12/159.mp3');
    });

    test('is nothing for a file that was never fetched', () async {
      await addSource(1);
      final file = await addFile(await addBook('A Book'));

      expect(await readDownloadedPath(db, file), isNull);
    });

    test('is nothing for a file the listener imported', () async {
      // The refusal that matters: this path ends in a real delete.
      await addSource(1);
      final file = await addFile(
        await addBook('A Local Book'),
        importedFrom: r'D:\Books\theirs.m4b',
      );

      expect(await readDownloadedPath(db, file), isNull);
    });

    test('is nothing for a file that has gone', () async {
      expect(await readDownloadedPath(db, 404), isNull);
    });

    test('and a whole book gives every downloaded file by id', () async {
      await addSource(1);
      final book = await addBook('A Book');
      final one = await addFile(
        book,
        fileKey: 'a.mp3',
        downloadedTo: '1/1.mp3',
      );
      final two = await addFile(
        book,
        fileKey: 'b.mp3',
        downloadedTo: '1/2.mp3',
      );
      await addFile(book, fileKey: 'c.mp3');
      await addFile(book, fileKey: 'd.mp3', importedFrom: r'D:\d.m4b');

      expect(await readDownloadedPathsOfBook(db, book), {
        one: '1/1.mp3',
        two: '1/2.mp3',
      });
    });

    test('and a book with nothing downloaded gives nothing', () async {
      await addSource(1);
      final book = await addBook('A Book');
      await addFile(book, importedFrom: r'D:\d.m4b');

      expect(await readDownloadedPathsOfBook(db, book), isEmpty);
    });
  });

  group('forgetting a downloaded file', () {
    test('clears the path and the task with it', () async {
      await addSource(1);
      final file = await addFile(
        await addBook('A Book'),
        downloadedTo: '12/159.mp3',
      );
      await addTask(file, state: DownloadState.completed);

      await forgetDownloadedFile(db, file);

      final row = await fileRow(file);
      expect(row.localPath, isNull);
      expect(row.downloadedAt, isNull);
      expect(
        await db.select(db.downloadTasks).get(),
        isEmpty,
        reason: 'the absence of a row is what "not asked for" means',
      );
    });

    test('leaves an imported file exactly as it was', () async {
      // The whole reason `downloaded_at` is checked here as well as in the read: clearing this row
      // would make a local book unplayable, and the caller would have deleted the listener's file.
      await addSource(1);
      final file = await addFile(
        await addBook('A Local Book'),
        importedFrom: r'D:\Books\theirs.m4b',
      );
      await addTask(file, state: DownloadState.completed);

      await forgetDownloadedFile(db, file);

      final row = await fileRow(file);
      expect(row.localPath, r'D:\Books\theirs.m4b');
      expect(await db.select(db.downloadTasks).get(), hasLength(1));
    });

    test('a file that has gone is not a failure', () async {
      await expectLater(forgetDownloadedFile(db, 404), completes);
    });

    test('leaves the rest of the book alone', () async {
      await addSource(1);
      final book = await addBook('A Book');
      final one = await addFile(
        book,
        fileKey: 'a.mp3',
        downloadedTo: '1/1.mp3',
      );
      final two = await addFile(
        book,
        fileKey: 'b.mp3',
        downloadedTo: '1/2.mp3',
      );
      await addTask(one, state: DownloadState.completed);
      await addTask(two, state: DownloadState.completed);

      await forgetDownloadedFile(db, one);

      expect((await fileRow(two)).localPath, '1/2.mp3');
      expect(await db.select(db.downloadTasks).get(), hasLength(1));
    });
  });

  group('retrying (§5.5)', () {
    Future<DownloadTaskRow> taskRow(int id) => (db.select(
      db.downloadTasks,
    )..where((t) => t.id.equals(id))).getSingle();

    test('forgives the attempts of a file that gave up', () async {
      await addSource(1);
      final task = await addTask(
        await addFile(await addBook('A Book')),
        state: DownloadState.failedPermanent,
        attempts: 5,
      );
      await (db.update(db.downloadTasks)..where((t) => t.id.equals(task)))
          .write(const DownloadTasksCompanion(lastError: Value('gave up')));

      await retryDownloadTask(db, task, clock: clock);

      final row = await taskRow(task);
      expect(row.state, DownloadState.queued);
      expect(row.attempts, 0);
      expect(row.lastError, isNull);
      expect(row.retryAt, isNull);
    });

    test('works for a cancelled and a paused one too', () async {
      await addSource(1);
      final book = await addBook('A Book');
      for (final state in [DownloadState.cancelled, DownloadState.paused]) {
        final task = await addTask(
          await addFile(book, fileKey: '${state.name}.mp3'),
          state: state,
        );
        await retryDownloadTask(db, task, clock: clock);
        expect(await taskRow(task).then((r) => r.state), DownloadState.queued);
      }
    });

    test('leaves a task that is still going where it is', () async {
      // Retrying something in flight would mean stopping it first, which is what cancel is for.
      await addSource(1);
      final task = await addTask(
        await addFile(await addBook('A Book')),
        state: DownloadState.downloading,
      );

      await retryDownloadTask(db, task, clock: clock);

      expect(
        await taskRow(task).then((r) => r.state),
        DownloadState.downloading,
      );
    });
  });
}
