import 'package:drift/drift.dart' hide isNull;
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import '../merge/book_details.dart';

/// The database-backed [PlaybackStore]: where the coordinator's progress, listening sessions and
/// per-book speed end up.
final class DriftPlaybackStore implements PlaybackStore {
  DriftPlaybackStore(this._db, {required this.deviceId, required Clock clock})
    : _clock = clock;

  final KikuyomiDatabase _db;
  final Clock _clock;

  /// Stored with progress and sessions (§4.3), so that sync can later tell devices apart.
  final String deviceId;

  /// One row per book in `playback_states`, replaced on every save, and the chapter's own last
  /// position alongside it. Both writes happen in one transaction, so Continue Listening and the
  /// chapter list can never disagree about where the listener is.
  @override
  Future<void> saveProgress({
    required int bookId,
    required ChapterPosition position,
    required int globalMs,
  }) {
    final now = _clock.now();
    return _db.transaction(() async {
      await _db
          .into(_db.playbackStates)
          .insertOnConflictUpdate(
            PlaybackStatesCompanion(
              bookId: Value(bookId),
              chapterId: Value(position.chapterId),
              chapterPositionMs: Value(position.offsetMs),
              globalPositionMs: Value(globalMs),
              updatedAt: Value(now),
              deviceId: Value(deviceId),
            ),
          );
      await (_db.update(
        _db.chapters,
      )..where((c) => c.id.equals(position.chapterId))).write(
        ChaptersCompanion(
          lastPositionMs: Value(position.offsetMs),
          updatedAt: Value(now),
        ),
      );
    });
  }

  @override
  Future<void> saveSession(ListeningSession session) async {
    await _db
        .into(_db.listeningSessions)
        .insert(
          ListeningSessionsCompanion(
            bookId: Value(session.bookId),
            chapterId: Value(session.chapterId),
            startedAt: Value(session.startedAt),
            endedAt: Value(session.endedAt),
            startGlobalMs: Value(session.startGlobalMs),
            endGlobalMs: Value(session.endGlobalMs),
            speed: Value(session.speed),
            deviceId: Value(deviceId),
          ),
        );
  }

  @override
  Future<void> saveSpeed({required int bookId, required double speed}) async {
    await (_db.update(_db.books)..where((b) => b.id.equals(bookId))).write(
      BooksCompanion(
        playbackSpeed: Value(speed),
        updatedAt: Value(_clock.now()),
      ),
    );
  }

  /// Replaces the file's estimate and corrects the book's length by as much as the file's changed.
  ///
  /// The length is corrected by the difference rather than summed afresh from the files, because it
  /// is not always their sum: a source may supply its own figure (§4.4), and a correction keeps
  /// whatever that figure rests on. A length the user edited is theirs and stays as they wrote it,
  /// and a book with no length is left without one.
  ///
  /// It all happens in one transaction that first checks the stored file is still an estimate, so
  /// a duration probed exactly in the meantime is never overwritten, and saving the same duration
  /// twice corrects the book's length only once.
  @override
  Future<void> saveLearnedDuration({
    required int bookId,
    required int fileId,
    required int durationMs,
  }) {
    return _db.transaction(() async {
      final file =
          await (_db.select(_db.mediaFiles)
                ..where((f) => f.id.equals(fileId) & f.bookId.equals(bookId)))
              .getSingleOrNull();
      if (file == null || !file.durationIsEstimate) return;

      await (_db.update(
        _db.mediaFiles,
      )..where((f) => f.id.equals(fileId))).write(
        MediaFilesCompanion(
          durationMs: Value(durationMs),
          durationIsEstimate: const Value(false),
        ),
      );

      final estimate = file.durationMs;
      final book = await (_db.select(
        _db.books,
      )..where((b) => b.id.equals(bookId))).getSingle();
      final total = book.totalDurationMs;
      if (estimate == null ||
          total == null ||
          book.userOverrides.contains(BookField.totalDurationMs)) {
        return;
      }
      await (_db.update(_db.books)..where((b) => b.id.equals(bookId))).write(
        BooksCompanion(
          totalDurationMs: Value(total + durationMs - estimate),
          updatedAt: Value(_clock.now()),
        ),
      );
    });
  }
}
