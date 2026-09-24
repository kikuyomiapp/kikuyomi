/// Putting files into the download queue, and reading what is in it (§5.2).
///
/// **The unit is a physical file.** "Download this book" enqueues the book's files and "download this
/// chapter" enqueues the files its segments reference, which for a thirty-chapter M4B is the same
/// single file either way. The `media_file_id` unique key makes that true rather than hoped for, so
/// asking twice is safe and asking for a chapter of a book already queued adds nothing.
///
/// **Nothing is resolved here.** §5.4 resolves just in time, as a file is about to start, because
/// many sources hand out URLs that expire within minutes; enqueueing a hundred-chapter book must not
/// cost a hundred calls to its source. A task therefore starts life with no `request_snapshot` at
/// all, and the scheduler fills one in when it picks the task up.
///
/// **A file already on the device is not queued.** A local book's files have a `local_path` from the
/// moment it was imported, and a downloaded file has one afterwards, so that one column answers both
/// "this is already here" and "there is nothing to fetch".
library;

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';

/// What asking for a download came to.
final class EnqueuedDownloads {
  const EnqueuedDownloads({
    required this.added,
    required this.alreadyQueued,
    required this.alreadyOnDevice,
  });

  /// Files that were not in the queue and now are.
  final int added;

  /// Files already queued, in flight, or waiting to be retried, which were left as they were.
  final int alreadyQueued;

  /// Files that need no fetching: a local book's own files, and anything already downloaded.
  final int alreadyOnDevice;

  /// Whether anything at all was asked of the network.
  bool get isEmpty => added == 0;

  /// Every file the request touched, however it was answered.
  int get total => added + alreadyQueued + alreadyOnDevice;

  @override
  String toString() =>
      'EnqueuedDownloads(added: $added, alreadyQueued: $alreadyQueued, '
      'alreadyOnDevice: $alreadyOnDevice)';
}

/// Queues every file of book [bookId] that is not already here.
///
/// §5.2: "Downloading a book enqueues all of its files." That includes the estimated rows a source
/// book carries before its chapters have been resolved — deliberately, because the resolver consumes
/// an estimate's row in place rather than replacing it, so the task queued against it is the task
/// that fetches the real file once the address is known.
Future<EnqueuedDownloads> enqueueBookDownload(
  KikuyomiDatabase db,
  int bookId, {
  required Clock clock,
  int priority = 0,
}) async {
  final files = await (db.select(
    db.mediaFiles,
  )..where((f) => f.bookId.equals(bookId))).get();
  return _enqueue(db, files, clock: clock, priority: priority);
}

/// Queues the files chapter [chapterId] is made of.
///
/// A chapter spanning three files queues three, and a chapter that is part of one shared file queues
/// that file — which may already be queued for a neighbouring chapter, and is then left alone.
Future<EnqueuedDownloads> enqueueChapterDownload(
  KikuyomiDatabase db,
  int chapterId, {
  required Clock clock,
  int priority = 0,
}) async {
  final query = db.select(db.chapterSegments).join([
    innerJoin(
      db.mediaFiles,
      db.mediaFiles.id.equalsExp(db.chapterSegments.mediaFileId),
    ),
  ])..where(db.chapterSegments.chapterId.equals(chapterId));
  query.orderBy([OrderingTerm.asc(db.chapterSegments.ordinal)]);
  final rows = await query.get();
  // A chapter may name one file in several segments; each file is queued once.
  final files = <int, MediaFileRow>{};
  for (final row in rows) {
    final file = row.readTable(db.mediaFiles);
    files[file.id] = file;
  }
  return _enqueue(db, files.values, clock: clock, priority: priority);
}

/// The shared path: one task per file, leaving alone what is already here or already asked for.
Future<EnqueuedDownloads> _enqueue(
  KikuyomiDatabase db,
  Iterable<MediaFileRow> files, {
  required Clock clock,
  required int priority,
}) async {
  var added = 0;
  var alreadyQueued = 0;
  var alreadyOnDevice = 0;

  await db.transaction(() async {
    for (final file in files) {
      if (file.localPath != null) {
        alreadyOnDevice++;
        continue;
      }
      final existing = await (db.select(
        db.downloadTasks,
      )..where((t) => t.mediaFileId.equals(file.id))).getSingleOrNull();
      if (existing == null) {
        await db
            .into(db.downloadTasks)
            .insert(
              DownloadTasksCompanion.insert(
                mediaFileId: file.id,
                state: DownloadState.queued,
                priority: Value(priority),
                createdAt: clock.now(),
                updatedAt: clock.now(),
              ),
            );
        added++;
        continue;
      }
      if (existing.state == DownloadState.completed) {
        alreadyOnDevice++;
        continue;
      }
      // Asking again for something that was given up on is how a listener retries it. Anything still
      // going is left where it is, but may be moved up the queue.
      if (existing.state == DownloadState.cancelled ||
          existing.state == DownloadState.failedPermanent ||
          existing.state == DownloadState.failedRetryable) {
        await (db.update(
          db.downloadTasks,
        )..where((t) => t.id.equals(existing.id))).write(
          DownloadTasksCompanion(
            state: const Value(DownloadState.queued),
            hold: const Value(null),
            attempts: const Value(0),
            lastError: const Value(null),
            retryAt: const Value(null),
            priority: Value(
              priority > existing.priority ? priority : existing.priority,
            ),
            updatedAt: Value(clock.now()),
          ),
        );
        added++;
      } else {
        if (priority > existing.priority) {
          await (db.update(
            db.downloadTasks,
          )..where((t) => t.id.equals(existing.id))).write(
            DownloadTasksCompanion(
              priority: Value(priority),
              updatedAt: Value(clock.now()),
            ),
          );
        }
        alreadyQueued++;
      }
    }
  });

  return EnqueuedDownloads(
    added: added,
    alreadyQueued: alreadyQueued,
    alreadyOnDevice: alreadyOnDevice,
  );
}

/// Every task in the queue, watched, worst-placed first: what a Downloads screen shows.
///
/// Ordered the way a person reads a queue — the ones that need attention, then the ones in flight,
/// then the ones waiting — rather than by id.
Stream<List<DownloadTaskRow>> watchDownloadQueue(KikuyomiDatabase db) =>
    (db.select(db.downloadTasks)..orderBy([
          (t) => OrderingTerm.desc(t.priority),
          (t) => OrderingTerm.asc(t.createdAt),
        ]))
        .watch();

/// The tasks belonging to book [bookId], watched, for its details screen.
Stream<List<DownloadTaskRow>> watchBookDownloads(
  KikuyomiDatabase db,
  int bookId,
) {
  final query = db.select(db.downloadTasks).join([
    innerJoin(
      db.mediaFiles,
      db.mediaFiles.id.equalsExp(db.downloadTasks.mediaFileId),
    ),
  ])..where(db.mediaFiles.bookId.equals(bookId));
  return query.watch().map(
    (rows) => [for (final row in rows) row.readTable(db.downloadTasks)],
  );
}

/// The tasks the scheduler may start, most wanted first (§5.2).
///
/// Only the states that are waiting on the app rather than on the world: a queued task, and one whose
/// URL went stale and has to be asked for again. A task waiting on Wi-Fi or on free space is the
/// scheduler's to reconsider when those change, not to pick up now.
Future<List<DownloadTaskRow>> readStartableDownloads(
  KikuyomiDatabase db, {
  int limit = 20,
}) =>
    (db.select(db.downloadTasks)
          ..where(
            (t) => t.state.isInValues([
              DownloadState.queued,
              DownloadState.needsResolve,
            ]),
          )
          ..orderBy([
            (t) => OrderingTerm.desc(t.priority),
            (t) => OrderingTerm.asc(t.createdAt),
          ])
          ..limit(limit))
        .get();

/// The task for file [mediaFileId], or null when it was never asked for.
Future<DownloadTaskRow?> readDownloadTask(
  KikuyomiDatabase db,
  int mediaFileId,
) => (db.select(
  db.downloadTasks,
)..where((t) => t.mediaFileId.equals(mediaFileId))).getSingleOrNull();
