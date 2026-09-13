/// One continuous stretch of listening, as §4.3's `listening_session` row records it.
///
/// The device id is not here; it belongs to the app, and whatever persists the session attaches it.
final class ListeningSession {
  const ListeningSession({
    required this.bookId,
    required this.chapterId,
    required this.startedAt,
    required this.endedAt,
    required this.startGlobalMs,
    required this.endGlobalMs,
    required this.speed,
  });

  final int bookId;
  final int chapterId;
  final DateTime startedAt;
  final DateTime endedAt;
  final int startGlobalMs;
  final int endGlobalMs;
  final double speed;

  /// Wall-clock time spent listening, which is what "time listened" statistics add up.
  Duration get listened => endedAt.difference(startedAt);

  /// How much of the book this stretch covered. At 2x speed this is about twice [listened].
  int get coveredMs => endGlobalMs - startGlobalMs;
}
