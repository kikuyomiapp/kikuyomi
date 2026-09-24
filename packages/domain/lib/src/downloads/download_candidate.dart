/// One download the scheduler could start (§5.2).
///
/// The five facts a scheduling decision needs, and no more. Deliberately not the database row: the
/// policy is a pure function and the store is an interface, so neither should have to know the shape
/// of a table for the other's sake. It lives here because the store interface hands these out and the
/// policy in `downloads` takes them, and the two must agree without either depending on the other.
library;

/// One task the scheduler could start.
///
/// Deliberately not the database row: the policy needs five facts, and taking only those keeps it
/// testable without a database and unbothered by columns that come later.
final class DownloadCandidate {
  const DownloadCandidate({
    required this.taskId,
    required this.sourceId,
    required this.priority,
    required this.askedAt,
    this.bytesTotal,
  });

  final int taskId;

  /// Which source the file comes from, for the per-source cap. Two books from one site share it,
  /// which is the point: the cap is a promise to the site, not to the book.
  final int sourceId;

  /// Higher goes first. The chapter about to be played is raised above the rest of its book.
  final int priority;

  /// When it was asked for, which orders tasks of equal priority so the queue is first-come.
  final DateTime askedAt;

  /// The whole file's size, when the site has said. Null before the first response, which is the
  /// ordinary case for a task that has never started.
  final int? bytesTotal;
}
