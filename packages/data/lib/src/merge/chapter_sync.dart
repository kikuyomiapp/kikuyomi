/// Chapter synchronisation, as docs/architecture.md §4.4 specifies it.
///
/// When a book is refreshed, the chapters the source reports now have to be reconciled with the
/// chapters already stored. Getting this wrong is how progress gets lost: §4.4 notes that sources
/// shuffling their URL schemes is one of the most common ways Mihon users lose it. The planner
/// here is pure, returning what should change rather than changing anything, so every rule is
/// testable without a database.
library;

/// A chapter as it is currently stored.
final class StoredChapter {
  const StoredChapter({
    required this.id,
    required this.key,
    required this.title,
    required this.sourceIndex,
    this.durationMs,
    this.publishedAt,
    this.group,
    this.removedFromSource = false,
    this.hasProgress = false,
    this.hasBookmarks = false,
    this.hasDownloads = false,
  });

  /// Surrogate key. Progress, bookmarks and downloads hang off this, so keeping it is what
  /// "carrying progress over" means.
  final int id;
  final String key;
  final String title;
  final int sourceIndex;
  final int? durationMs;

  /// `chapter.published_at`: when the source released the chapter, for serials.
  final DateTime? publishedAt;

  /// `chapter.group_name`: a part or volume heading, such as "Part One".
  final String? group;

  final bool removedFromSource;
  final bool hasProgress;
  final bool hasBookmarks;
  final bool hasDownloads;

  /// §4.4: a removed chapter is kept indefinitely if it carries any of these.
  bool get carriesUserData => hasProgress || hasBookmarks || hasDownloads;
}

/// A chapter as the source reports it now.
///
/// Every field of §4.3's `chapter` row that a source provides is here: the two that the contract's
/// `ChapterInfo` carries beyond a title and a duration — `publishedAt`, for serials that release
/// chapters over time, and `group`, a part or volume heading — have columns of their own, so a
/// refresh that changes only a heading is still a change.
final class IncomingChapter {
  const IncomingChapter({
    required this.key,
    required this.title,
    required this.sourceIndex,
    this.durationMs,
    this.publishedAt,
    this.group,
  });

  final String key;
  final String title;
  final int sourceIndex;
  final int? durationMs;

  /// When the source released the chapter. In UTC.
  final DateTime? publishedAt;

  /// A part or volume heading, such as "Part One".
  final String? group;
}

/// One thing to do to reconcile stored chapters with incoming ones.
sealed class ChapterChange {
  const ChapterChange();
}

/// A chapter the source reports for the first time.
final class InsertChapter extends ChapterChange {
  const InsertChapter(this.chapter);

  final IncomingChapter chapter;
}

/// A stored chapter whose key still exists but whose fields changed, or which the source has
/// brought back after previously dropping it.
final class UpdateChapter extends ChapterChange {
  const UpdateChapter({
    required this.id,
    required this.chapter,
    required this.restored,
  });

  final int id;
  final IncomingChapter chapter;

  /// True when the chapter had been soft-deleted and has reappeared.
  final bool restored;
}

/// A stored chapter the source now reports under a different key.
///
/// The stored id survives, so progress, bookmarks and downloads carry over.
final class RenameChapter extends ChapterChange {
  const RenameChapter({
    required this.id,
    required this.previousKey,
    required this.chapter,
  });

  final int id;
  final String previousKey;
  final IncomingChapter chapter;
}

/// A stored chapter the source no longer reports. Always a soft delete.
final class RemoveChapter extends ChapterChange {
  const RemoveChapter({required this.id, required this.purgeable});

  final int id;

  /// True when the chapter carries no progress, bookmarks or downloads, so nothing is lost if it
  /// is eventually purged. When false it must be kept indefinitely.
  final bool purgeable;
}

/// Plans how to reconcile [stored] chapters with [incoming] ones.
///
/// The rules, from §4.4:
///
/// - Chapters match by key. New keys are inserted.
/// - Keys that disappear are soft-deleted, and marked non-purgeable if they carry user data.
/// - Changed ordering, titles, durations, release times or group headings update the stored row.
/// - When a key changes but the title and index match and the durations are within
///   [durationToleranceMs], the chapter is treated as renamed and keeps its identity.
///
/// Choices the section leaves open, made here conservatively:
///
/// - Titles are compared exactly after trimming whitespace, and an empty title never matches, since
///   untitled chapters would otherwise pair on index alone.
/// - A duration unknown on either side does not rule out a rename. Title and index matching is
///   already strong evidence, and many sources report no duration until a file is probed.
/// - A release time or a group heading the source stops reporting does not erase the stored one,
///   exactly as a duration does not: sources drop fields through flakiness more often than on
///   purpose. Neither takes part in rename matching, because a heading is shared by every chapter
///   of a part and a release time is often absent, so neither tells two chapters apart.
/// - A rename must be one-to-one. If an incoming chapter could be several stored ones, or a stored
///   chapter several incoming ones, nothing is renamed and the ordinary insert and remove apply.
///   Losing a rename loses progress visibly; a wrong rename attaches it silently to the wrong
///   chapter, which is worse.
/// - Only chapters that disappear in this sync are rename candidates. A chapter soft-deleted in an
///   earlier sync is restored only if its own key returns.
///
/// Changes for incoming chapters come first, in the source's order, followed by removals.
///
/// Throws [ArgumentError] if either list repeats a key.
List<ChapterChange> planChapterSync({
  required List<StoredChapter> stored,
  required List<IncomingChapter> incoming,
  int durationToleranceMs = 2000,
}) {
  final storedByKey = <String, StoredChapter>{};
  for (final chapter in stored) {
    if (storedByKey.containsKey(chapter.key)) {
      throw ArgumentError.value(chapter.key, 'stored', 'repeats a key');
    }
    storedByKey[chapter.key] = chapter;
  }
  final incomingKeys = <String>{};
  for (final chapter in incoming) {
    if (!incomingKeys.add(chapter.key)) {
      throw ArgumentError.value(chapter.key, 'incoming', 'repeats a key');
    }
  }

  // Decisions are collected first and emitted afterwards, so the output follows the source's order
  // regardless of which pass reached each decision.
  final updates = <IncomingChapter, UpdateChapter>{};
  final unmatched = <IncomingChapter>[];
  final matchedIds = <int>{};

  for (final chapter in incoming) {
    final existing = storedByKey[chapter.key];
    if (existing == null) {
      unmatched.add(chapter);
      continue;
    }
    matchedIds.add(existing.id);
    final changed =
        existing.removedFromSource ||
        existing.title != chapter.title ||
        existing.sourceIndex != chapter.sourceIndex ||
        (chapter.durationMs != null &&
            chapter.durationMs != existing.durationMs) ||
        (chapter.publishedAt != null &&
            chapter.publishedAt != existing.publishedAt) ||
        (chapter.group != null && chapter.group != existing.group);
    if (changed) {
      updates[chapter] = UpdateChapter(
        id: existing.id,
        chapter: chapter,
        restored: existing.removedFromSource,
      );
    }
  }

  final disappeared = [
    for (final chapter in stored)
      if (!matchedIds.contains(chapter.id) && !chapter.removedFromSource)
        chapter,
  ];

  bool isRenameOf(StoredChapter old, IncomingChapter now) {
    final title = now.title.trim();
    if (title.isEmpty || old.title.trim() != title) return false;
    if (old.sourceIndex != now.sourceIndex) return false;
    final a = old.durationMs;
    final b = now.durationMs;
    return a == null || b == null || (a - b).abs() <= durationToleranceMs;
  }

  final candidatesFor = <IncomingChapter, List<StoredChapter>>{
    for (final now in unmatched)
      now: [
        for (final old in disappeared)
          if (isRenameOf(old, now)) old,
      ],
  };
  final claimsOn = <int, int>{};
  for (final candidates in candidatesFor.values) {
    for (final old in candidates) {
      claimsOn[old.id] = (claimsOn[old.id] ?? 0) + 1;
    }
  }

  final changes = <ChapterChange>[];
  final renamedIds = <int>{};
  final unmatchedSet = unmatched.toSet();
  for (final now in incoming) {
    final update = updates[now];
    if (update != null) {
      changes.add(update);
      continue;
    }
    // Matched by key and unchanged: nothing to do.
    if (!unmatchedSet.contains(now)) continue;
    final candidates = candidatesFor[now]!;
    final unique =
        candidates.length == 1 && claimsOn[candidates.single.id] == 1;
    if (unique) {
      final old = candidates.single;
      renamedIds.add(old.id);
      changes.add(
        RenameChapter(id: old.id, previousKey: old.key, chapter: now),
      );
    } else {
      changes.add(InsertChapter(now));
    }
  }

  for (final old in disappeared) {
    if (renamedIds.contains(old.id)) continue;
    changes.add(RemoveChapter(id: old.id, purgeable: !old.carriesUserData));
  }

  return changes;
}
