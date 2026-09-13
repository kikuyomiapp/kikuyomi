import 'package:drift/drift.dart' hide isNull;
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';

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
}
