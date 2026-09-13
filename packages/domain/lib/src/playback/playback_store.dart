import '../timeline/positions.dart';
import 'listening_session.dart';

/// Where playback persists what it produces.
///
/// A service interface, so it lives in the domain (§2.4): the data layer implements it over the
/// database and the playback coordinator consumes it, and neither has to know about the other.
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
