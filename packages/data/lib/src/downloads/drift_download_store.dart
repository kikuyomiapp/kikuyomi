/// The download queue over Drift: §5.2's source of truth (§2.4's data layer).
///
/// `DownloadStore` is the domain's interface and this is the implementation, exactly as
/// `DriftPlaybackStore` is for `PlaybackStore`. Everything the driver learns is written here before
/// it is acted on, because ADR-0007 makes the table the thing that survives a process kill and the
/// transport's own idea of itself the thing that does not.
library;

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';

/// The queue, backed by the `download_task` table.
final class DriftDownloadStore implements DownloadStore {
  const DriftDownloadStore(this._db, {required Clock clock}) : _clock = clock;

  final KikuyomiDatabase _db;
  final Clock _clock;

  @override
  Future<List<DownloadCandidate>> readStartable({int limit = 20}) async {
    // The source id comes from the file's book, which is two joins away: a task names a file, a file
    // belongs to a book, and a book came from a source. The per-source cap is a promise to a site,
    // so it has to be the site's id rather than the book's.
    final query =
        _db.select(_db.downloadTasks).join([
          innerJoin(
            _db.mediaFiles,
            _db.mediaFiles.id.equalsExp(_db.downloadTasks.mediaFileId),
          ),
          innerJoin(_db.books, _db.books.id.equalsExp(_db.mediaFiles.bookId)),
        ])..where(
          _db.downloadTasks.state.isInValues([
            DownloadState.queued,
            DownloadState.needsResolve,
          ]),
        );
    query
      ..orderBy([
        OrderingTerm.desc(_db.downloadTasks.priority),
        OrderingTerm.asc(_db.downloadTasks.createdAt),
        OrderingTerm.asc(_db.downloadTasks.id),
      ])
      ..limit(limit);

    return [
      for (final row in await query.get())
        DownloadCandidate(
          taskId: row.readTable(_db.downloadTasks).id,
          sourceId: row.readTable(_db.books).sourceId,
          priority: row.readTable(_db.downloadTasks).priority,
          askedAt: row.readTable(_db.downloadTasks).createdAt,
          bytesTotal: row.readTable(_db.downloadTasks).bytesTotal,
        ),
    ];
  }

  @override
  Future<Map<int, int>> countRunningBySource() async {
    final query =
        _db.select(_db.downloadTasks).join([
          innerJoin(
            _db.mediaFiles,
            _db.mediaFiles.id.equalsExp(_db.downloadTasks.mediaFileId),
          ),
          innerJoin(_db.books, _db.books.id.equalsExp(_db.mediaFiles.bookId)),
        ])..where(
          _db.downloadTasks.state.isInValues([
            DownloadState.resolving,
            DownloadState.downloading,
            DownloadState.processing,
          ]),
        );

    final counts = <int, int>{};
    for (final row in await query.get()) {
      final source = row.readTable(_db.books).sourceId;
      counts[source] = (counts[source] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Future<DownloadSubject?> readSubject(int taskId) async {
    final query = _db.select(_db.downloadTasks).join([
      innerJoin(
        _db.mediaFiles,
        _db.mediaFiles.id.equalsExp(_db.downloadTasks.mediaFileId),
      ),
    ])..where(_db.downloadTasks.id.equals(taskId));
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    final task = row.readTable(_db.downloadTasks);
    final file = row.readTable(_db.mediaFiles);
    return DownloadSubject(
      taskId: task.id,
      mediaFileId: file.id,
      bookId: file.bookId,
      state: task.state,
      attempts: task.attempts,
      request: task.requestSnapshot,
      expiresAt: task.expiresAt,
    );
  }

  @override
  Future<void> saveState(
    int taskId,
    DownloadState state, {
    DownloadHold? hold,
  }) async {
    await (_db.update(
      _db.downloadTasks,
    )..where((t) => t.id.equals(taskId))).write(
      DownloadTasksCompanion(
        state: Value(state),
        // Cleared by every state but `waiting`, so a task that is moving does not go on claiming
        // it wants Wi-Fi.
        hold: Value(state == DownloadState.waiting ? hold : null),
        updatedAt: Value(_clock.now()),
      ),
    );
  }

  @override
  Future<void> saveResolution(
    int taskId, {
    required DownloadRequest request,
    DateTime? expiresAt,
  }) async {
    await (_db.update(
      _db.downloadTasks,
    )..where((t) => t.id.equals(taskId))).write(
      DownloadTasksCompanion(
        requestSnapshot: Value(request),
        expiresAt: Value(expiresAt),
        updatedAt: Value(_clock.now()),
      ),
    );
  }

  @override
  Future<void> saveProgress(
    int taskId, {
    required int bytesDone,
    int? bytesTotal,
  }) async {
    await (_db.update(
      _db.downloadTasks,
    )..where((t) => t.id.equals(taskId))).write(
      DownloadTasksCompanion(
        bytesDone: Value(bytesDone),
        // Written only once the site has said, so a progress bar never guesses.
        bytesTotal: bytesTotal == null
            ? const Value.absent()
            : Value(bytesTotal),
        updatedAt: Value(_clock.now()),
      ),
    );
  }

  @override
  Future<void> saveFailure(
    int taskId, {
    required String error,
    required bool permanent,
    DateTime? retryAt,
  }) async {
    await _db.transaction(() async {
      final task = await (_db.select(
        _db.downloadTasks,
      )..where((t) => t.id.equals(taskId))).getSingleOrNull();
      if (task == null) return;
      await (_db.update(
        _db.downloadTasks,
      )..where((t) => t.id.equals(taskId))).write(
        DownloadTasksCompanion(
          state: Value(
            permanent
                ? DownloadState.failedPermanent
                : DownloadState.failedRetryable,
          ),
          hold: const Value(null),
          attempts: Value(task.attempts + 1),
          lastError: Value(error),
          retryAt: Value(permanent ? null : retryAt),
          updatedAt: Value(_clock.now()),
        ),
      );
    });
  }

  @override
  Future<void> saveTransportId(int taskId, String? transportTaskId) async {
    await (_db.update(
      _db.downloadTasks,
    )..where((t) => t.id.equals(taskId))).write(
      DownloadTasksCompanion(
        transportTaskId: Value(transportTaskId),
        updatedAt: Value(_clock.now()),
      ),
    );
  }

  @override
  Future<void> saveCompleted(int taskId, {required String localPath}) async {
    // The file's path and the task's completion are written together. Anything that reads both — the
    // resolver deciding whether a chapter needs the network, a screen showing a book as downloaded —
    // must never see a finished download whose file is not there (§5.7).
    await _db.transaction(() async {
      final task = await (_db.select(
        _db.downloadTasks,
      )..where((t) => t.id.equals(taskId))).getSingleOrNull();
      if (task == null) return;
      await (_db.update(
        _db.mediaFiles,
      )..where((f) => f.id.equals(task.mediaFileId))).write(
        MediaFilesCompanion(
          localPath: Value(localPath),
          downloadedAt: Value(_clock.now()),
        ),
      );
      await (_db.update(
        _db.downloadTasks,
      )..where((t) => t.id.equals(taskId))).write(
        DownloadTasksCompanion(
          state: const Value(DownloadState.completed),
          hold: const Value(null),
          lastError: const Value(null),
          retryAt: const Value(null),
          updatedAt: Value(_clock.now()),
        ),
      );
    });
  }

  @override
  Future<List<int>> readRetryDue(DateTime now) async {
    final rows =
        await (_db.select(_db.downloadTasks)..where(
              (t) =>
                  t.state.equalsValue(DownloadState.failedRetryable) &
                  t.retryAt.isNotNull() &
                  t.retryAt.isSmallerOrEqualValue(now),
            ))
            .get();
    return [for (final row in rows) row.id];
  }
}
