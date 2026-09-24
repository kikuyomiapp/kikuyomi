/// What is on the device, and letting go of it (§5.6).
///
/// The queue in `download_queue.dart` is about fetching files; this is about the ones that arrived.
/// It answers what the Downloads screen lists, and it performs the one destructive operation the
/// download system has.
///
/// **Deleting refuses to touch a file that was not downloaded.** A local book's `local_path` points at
/// the listener's own file, wherever they keep it — the folder they imported from, a drive, a NAS —
/// and clearing that column would make the book unplayable while deleting the file behind it would
/// destroy something the app did not create and cannot get back. `downloaded_at` is what separates
/// the two, it is written by the download queue and by nothing else, and every function here that
/// could delete something checks it first. That is why they return a path rather than take one: the
/// caller cannot name a file to delete, it can only ask which file a row is responsible for.
library;

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';

/// One physical file the Downloads screen has something to say about (§5.6).
///
/// The unit is a file rather than a chapter, as it is everywhere else in §5.2, and the screen groups
/// them by book itself. A file is here exactly as long as it has a task: a finished download keeps its
/// row, and deleting the file takes the row with it.
final class DownloadEntry {
  const DownloadEntry({
    required this.task,
    required this.bookId,
    required this.bookTitle,
    required this.fileKey,
    required this.isOnDevice,
    this.sizeBytes,
  });

  /// The queue's row: its state, how far it got, what went wrong.
  final DownloadTaskRow task;

  final int bookId;

  /// What to call the book it belongs to. Carried here so the screen does not join the library again
  /// for every row it draws.
  final String bookTitle;

  /// What the source calls the file. The only name it has, since a file may span chapters and a
  /// chapter may span files.
  final String fileKey;

  /// Whether the bytes are really here, as opposed to asked for.
  final bool isOnDevice;

  /// What it takes on disk, as well as it is known: what the site said while fetching it, or what the
  /// source declared, and null when neither ever said.
  final int? sizeBytes;

  int get mediaFileId => task.mediaFileId;
}

/// Everything the download system is holding or fetching, watched (§5.6).
///
/// Ordered by book and then by file, which for a source that names its files in reading order is
/// reading order. The screen sorts the books themselves, because what belongs at the top — whatever
/// is downloading now — is a presentation decision.
Stream<List<DownloadEntry>> watchDownloads(KikuyomiDatabase db) {
  final query = db.select(db.downloadTasks).join([
    innerJoin(
      db.mediaFiles,
      db.mediaFiles.id.equalsExp(db.downloadTasks.mediaFileId),
    ),
    innerJoin(db.books, db.books.id.equalsExp(db.mediaFiles.bookId)),
  ]);
  query.orderBy([
    OrderingTerm.asc(db.books.title),
    OrderingTerm.asc(db.mediaFiles.id),
  ]);
  return query.watch().map(
    (rows) => [
      for (final row in rows)
        _entryOf(
          row.readTable(db.downloadTasks),
          row.readTable(db.mediaFiles),
          row.readTable(db.books),
        ),
    ],
  );
}

DownloadEntry _entryOf(DownloadTaskRow task, MediaFileRow file, BookRow book) =>
    DownloadEntry(
      task: task,
      bookId: book.id,
      bookTitle: book.title,
      fileKey: file.fileKey,
      // Downloaded, rather than merely on the device: a local book's file is on the device too, and
      // is not the download system's to speak for.
      isOnDevice: file.downloadedAt != null && file.localPath != null,
      // What the site said while fetching it is the better figure, because a source's declared size
      // is often absent and occasionally wrong.
      sizeBytes: task.bytesTotal ?? file.sizeBytes,
    );

/// What all the downloaded files of the library come to, for the screen's total (§5.6).
///
/// From the recorded sizes rather than from the disk, so it costs one query rather than a walk of
/// every folder. A file whose size nothing ever stated counts as nothing, which understates the
/// total; `DownloadedFiles.totalBytes` measures the disk itself when the exact figure matters.
Future<int> downloadedBytes(KikuyomiDatabase db) async {
  final query = db.select(db.downloadTasks).join([
    innerJoin(
      db.mediaFiles,
      db.mediaFiles.id.equalsExp(db.downloadTasks.mediaFileId),
    ),
  ])..where(db.mediaFiles.downloadedAt.isNotNull());
  var total = 0;
  for (final row in await query.get()) {
    total +=
        row.readTable(db.downloadTasks).bytesTotal ??
        row.readTable(db.mediaFiles).sizeBytes ??
        0;
  }
  return total;
}

/// Where file [mediaFileId] is kept, relative to the downloads folder, or null when the download
/// system is not holding it.
///
/// Null covers both a file that was never fetched and one the listener imported. See this library's
/// note: an imported file is not the download system's to delete.
Future<String?> readDownloadedPath(KikuyomiDatabase db, int mediaFileId) async {
  final file = await (db.select(
    db.mediaFiles,
  )..where((f) => f.id.equals(mediaFileId))).getSingleOrNull();
  if (file == null || file.downloadedAt == null) return null;
  return file.localPath;
}

/// Where every downloaded file of book [bookId] is kept, by file id.
///
/// For deleting a whole book's downloads. A book with nothing downloaded gives an empty map, and a
/// local book gives an empty map however many files it has.
Future<Map<int, String>> readDownloadedPathsOfBook(
  KikuyomiDatabase db,
  int bookId,
) async {
  final files =
      await (db.select(db.mediaFiles)..where(
            (f) =>
                f.bookId.equals(bookId) &
                f.downloadedAt.isNotNull() &
                f.localPath.isNotNull(),
          ))
          .get();
  return {for (final file in files) file.id: file.localPath!};
}

/// Records that file [mediaFileId] is no longer on the device, and forgets the task that fetched it.
///
/// Called after the file itself has gone, so that a delete that failed — a file the player still has
/// open, which is how Windows behaves — leaves the row saying the file is here, which it is.
///
/// Refuses a file that was not downloaded, so a local book cannot be unplayed by this path. Deleting
/// the task rather than marking it is what lets the listener ask for the file again: `download_task`
/// has one row per file, and the absence of a row is what "not asked for" means.
Future<void> forgetDownloadedFile(KikuyomiDatabase db, int mediaFileId) async {
  await db.transaction(() async {
    final file = await (db.select(
      db.mediaFiles,
    )..where((f) => f.id.equals(mediaFileId))).getSingleOrNull();
    if (file == null || file.downloadedAt == null) return;
    await (db.update(
      db.mediaFiles,
    )..where((f) => f.id.equals(mediaFileId))).write(
      const MediaFilesCompanion(
        localPath: Value(null),
        downloadedAt: Value(null),
      ),
    );
    await (db.delete(
      db.downloadTasks,
    )..where((t) => t.mediaFileId.equals(mediaFileId))).go();
  });
}

/// Puts task [taskId] back in the queue, with its attempts forgiven (§5.5).
///
/// How the listener retries a file that gave up, and how a cancelled one is asked for again. A task
/// that is still going is left alone: retrying it would mean stopping it first, which is what pause
/// and cancel are for.
Future<void> retryDownloadTask(
  KikuyomiDatabase db,
  int taskId, {
  required Clock clock,
}) async {
  await (db.update(db.downloadTasks)..where(
        (t) =>
            t.id.equals(taskId) &
            t.state.isInValues([
              DownloadState.failedPermanent,
              DownloadState.failedRetryable,
              DownloadState.cancelled,
              DownloadState.paused,
            ]),
      ))
      .write(
        DownloadTasksCompanion(
          state: const Value(DownloadState.queued),
          hold: const Value(null),
          attempts: const Value(0),
          lastError: const Value(null),
          retryAt: const Value(null),
          updatedAt: Value(clock.now()),
        ),
      );
}
