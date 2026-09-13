import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'listening_sessions.dart';

/// Where the coordinator persists what playback produces.
///
/// The data layer implements this over the database. Keeping it an interface here is what lets the
/// coordinator be tested without one, and keeps this package free of Drift.
abstract interface class PlaybackStore {
  /// Progress for a book. [position] is the truth (§4.5); [globalMs] is derived and cached for
  /// sorting Continue Listening.
  Future<void> saveProgress({
    required int bookId,
    required ChapterPosition position,
    required int globalMs,
  });

  /// A finished stretch of listening, for history and statistics.
  Future<void> saveSession(ListeningSession session);

  /// §4.3: playback speed is remembered per book.
  Future<void> saveSpeed({required int bookId, required double speed});
}
