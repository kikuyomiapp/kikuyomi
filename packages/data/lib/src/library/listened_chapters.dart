import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import 'book_queries.dart';
import 'listened_backfill.dart';

/// Marks chapters [chapterIds] of book [bookId] as [listened], or as not listened, by hand (§4.5),
/// and returns the ids of the chapters whose state this changed.
///
/// The recorded state is the truth a book's details, Continue Listening and the player all read, so
/// a mark by hand wins over wherever the listener has been. A chapter marked listened is recorded as
/// of now, as playback would record it; one marked not listened loses the time it was recorded.
///
/// Positions are left alone: the book's saved progress and each chapter's last position stay where
/// they are, so marking never loses the listener's place, and marking a chapter listened again
/// finds everything as it was. A chapter marked not listened while its position is past its
/// threshold is recorded as listened again the next time progress is saved there, which is §4.5's
/// rule for playback and what listening on from that place means.
///
/// Chapters of another book, and chapters already in the state asked for, are left as they are,
/// and are not among those returned.
Future<Set<int>> setChaptersListened(
  KikuyomiDatabase db, {
  required int bookId,
  required Iterable<int> chapterIds,
  required bool listened,
  required Clock clock,
}) {
  final ids = chapterIds.toSet();
  return db.transaction(() => _mark(db, bookId, ids, listened, clock));
}

/// Marks book [bookId] finished by hand: every chapter it lists, which is all but those the source
/// no longer reports, is recorded as listened (§4.5).
///
/// Returns the chapters that were not listened before, which are the ones to mark not listened
/// again to undo it. Positions are left alone, as [setChaptersListened] explains.
Future<Set<int>> markBookFinished(
  KikuyomiDatabase db,
  int bookId, {
  required Clock clock,
}) => db.transaction(() async {
  final listed =
      await (db.selectOnly(db.chapters)
            ..addColumns([db.chapters.id])
            ..where(
              db.chapters.bookId.equals(bookId) &
                  db.chapters.removedFromSource.equals(false),
            ))
          .map((row) => row.read(db.chapters.id)!)
          .get();
  return _mark(db, bookId, listed.toSet(), true, clock);
});

/// Marks book [bookId] not finished by hand: its last chapter, whose listened state is what makes a
/// book finished (§4.5), is recorded as not listened.
///
/// Its other chapters keep their state, as they do when a finished book is started again, and its
/// positions are left alone, as [setChaptersListened] explains. Returns the chapter it changed, or
/// nothing for a book that was not finished.
Future<Set<int>> markBookNotFinished(
  KikuyomiDatabase db,
  int bookId, {
  required Clock clock,
}) => db.transaction(() async {
  final last = (await lastPlayableChapters(db, [bookId]))[bookId];
  if (last == null) return const <int>{};
  return _mark(db, bookId, {last.id}, false, clock);
});

/// Records as listened every chapter whose saved position has reached its listened threshold
/// (§4.5) but that is not yet recorded as listened, and returns how many it recorded.
///
/// It is for chapters listened to before listened state was recorded, when it was worked out from
/// positions every time it was shown, so that recording it does not suddenly show them as
/// unlistened. It reads positions as that working-out did: for the chapter a book's saved progress is
/// in, the progress itself, even at the chapter's very start; for any other chapter, its last
/// position, once the listener has been in it. A chapter's duration comes from the Timeline the
/// player builds for its book or, for a chapter not on it, from the chapter's row, and a chapter
/// whose duration is unknown is left alone. The time it is recorded as listened is the chapter's
/// `updatedAt`, which is when progress was last saved in it unless something has changed the row
/// since: the best evidence there is, and nearer the truth than the moment this runs. Nothing else
/// about the chapter changes, `updatedAt` included, since nothing the listener did changed.
///
/// Running it twice changes nothing the second time, since every chapter it would record is
/// recorded, and it moves no position. All the same it must run only once, before the listener can
/// mark anything by hand: run later, it would record again a chapter the listener marked not
/// listened whose position is past its threshold. [backfillListenedChaptersOnce] sees to that.
Future<int> backfillListenedChapters(KikuyomiDatabase db) =>
    db.transaction(() => recordListenedFromPositions(db));

/// Runs [backfillListenedChapters] the first time it is called for this installation, which
/// [AppSettings.listenedBackfilled] records, and does nothing after that.
///
/// The app calls it as it starts, before anything reads or records listened state. The setting is
/// written only once the backfill has finished; the backfill is one transaction, so one cut short
/// leaves nothing behind and runs again whole at the next start.
Future<void> backfillListenedChaptersOnce(
  KikuyomiDatabase db,
  SettingsStore settings,
) async {
  if (settings.read(AppSettings.listenedBackfilled) ?? false) return;
  await backfillListenedChapters(db);
  await settings.write(AppSettings.listenedBackfilled, true);
}

/// [setChaptersListened] without a transaction of its own.
Future<Set<int>> _mark(
  KikuyomiDatabase db,
  int bookId,
  Set<int> chapterIds,
  bool listened,
  Clock clock,
) async {
  if (chapterIds.isEmpty) return const {};
  final changing =
      await (db.selectOnly(db.chapters)
            ..addColumns([db.chapters.id])
            ..where(
              db.chapters.bookId.equals(bookId) &
                  db.chapters.id.isIn(chapterIds) &
                  db.chapters.isListened.equals(!listened),
            ))
          .map((row) => row.read(db.chapters.id)!)
          .get();
  if (changing.isEmpty) return const {};
  final now = clock.now();
  await (db.update(db.chapters)..where((c) => c.id.isIn(changing))).write(
    ChaptersCompanion(
      isListened: Value(listened),
      listenedAt: Value(listened ? now : null),
      updatedAt: Value(now),
    ),
  );
  return changing.toSet();
}
