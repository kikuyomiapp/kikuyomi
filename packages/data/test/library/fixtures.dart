// Books added and listened to the way the app does it, for tests of what the library shows.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';

final start = DateTime.utc(2026, 9, 14, 8);

KikuyomiDatabase openDatabase() => KikuyomiDatabase(NativeDatabase.memory());

/// Opening of 10 minutes, Middle of 20 and End of 5. Middle is long enough for 3 percent to be more
/// than 30 seconds.
const threeParts = [('Opening', 600000), ('Middle', 1200000), ('End', 300000)];

/// A book of one file per chapter, as a folder of MP3s is added. Its files are `1.mp3`, `2.mp3` and
/// so on under a folder named after the book.
Future<int> addFolderBook(
  KikuyomiDatabase db,
  Clock clock, {
  String title = 'A Book',
  List<(String, int)> parts = threeParts,
  List<String> authors = const ['An Author', 'Second Author'],
  List<String> narrators = const ['A Narrator'],
}) => importLocalFolderBook(
  db,
  LocalFolderImport(
    key: 'C:/Books/$title',
    title: title,
    authors: authors,
    narrators: narrators,
    tracks: [
      for (final (index, (name, durationMs)) in parts.indexed)
        LocalTrackImport(
          file: LocalBookFile(
            path: 'C:/Books/$title/${index + 1}.mp3',
            durationMs: durationMs,
            format: 'mp3',
          ),
          title: name,
        ),
    ],
  ),
  clock: clock,
);

/// Three embedded chapters of 20 minutes each.
const hourMarkers = [
  TimelineMarker(title: 'Chapter One', startMs: 0),
  TimelineMarker(title: 'Chapter Two', startMs: 1200000),
  TimelineMarker(title: 'Chapter Three', startMs: 2400000),
];

/// A single M4B of an hour.
Future<int> addM4b(
  KikuyomiDatabase db,
  Clock clock, {
  String title = 'One File',
  List<TimelineMarker> markers = hourMarkers,
}) => importLocalBook(
  db,
  LocalBookImport(
    file: LocalBookFile(
      path: 'C:/Books/$title.m4b',
      durationMs: 3600000,
      format: 'm4b',
      markers: markers,
    ),
    title: title,
    authors: const ['An Author'],
  ),
  clock: clock,
);

/// The ids of a book's chapters in source order, removed ones included.
Future<List<int>> chapterIdsOf(KikuyomiDatabase db, int bookId) async => [
  for (final chapter
      in await (db.select(db.chapters)
            ..where((c) => c.bookId.equals(bookId))
            ..orderBy([(c) => OrderingTerm.asc(c.sourceIndex)]))
          .get())
    chapter.id,
];

/// Saves progress as the player does, [offsetMs] into the playable chapter at [chapterIndex],
/// recording the chapter listened once that reaches its threshold (§4.5), then moves the clock on a
/// minute so the next save is later.
Future<void> listen(
  KikuyomiDatabase db,
  FakeClock clock,
  int bookId,
  int chapterIndex,
  int offsetMs,
) async {
  final timeline = (await loadStoredPlayback(db, bookId)).timeline;
  final position = ChapterPosition(
    chapterId: timeline.chapterIds[chapterIndex],
    offsetMs: offsetMs,
  );
  await DriftPlaybackStore(
    db,
    deviceId: 'test-device',
    clock: clock,
  ).saveProgress(
    bookId: bookId,
    position: position,
    globalMs: timeline.globalOf(position),
    listened: timeline.isChapterListened(position),
  );
  clock.advance(const Duration(minutes: 1));
}

/// Saves progress as the app did before it recorded listened state, never recording a chapter as
/// listened, then moves the clock on a minute.
Future<void> listenBeforeRecording(
  KikuyomiDatabase db,
  FakeClock clock,
  int bookId,
  int chapterIndex,
  int offsetMs,
) async {
  final timeline = (await loadStoredPlayback(db, bookId)).timeline;
  final position = ChapterPosition(
    chapterId: timeline.chapterIds[chapterIndex],
    offsetMs: offsetMs,
  );
  await DriftPlaybackStore(
    db,
    deviceId: 'test-device',
    clock: clock,
  ).saveProgress(
    bookId: bookId,
    position: position,
    globalMs: timeline.globalOf(position),
    listened: false,
  );
  clock.advance(const Duration(minutes: 1));
}

/// Marks chapters listened or not by hand, as a book's details do, then moves the clock on a minute.
Future<Set<int>> mark(
  KikuyomiDatabase db,
  FakeClock clock,
  int bookId,
  List<int> chapterIds, {
  required bool listened,
}) async {
  final changed = await setChaptersListened(
    db,
    bookId: bookId,
    chapterIds: chapterIds,
    listened: listened,
    clock: clock,
  );
  clock.advance(const Duration(minutes: 1));
  return changed;
}

/// Chapter [chapterId] as it is stored.
Future<ChapterRow> chapterRow(KikuyomiDatabase db, int chapterId) =>
    (db.select(db.chapters)..where((c) => c.id.equals(chapterId))).getSingle();
