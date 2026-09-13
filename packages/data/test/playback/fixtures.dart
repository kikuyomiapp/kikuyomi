// Seeding helpers for tests that need a book laid out in the database.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

final seedTime = DateTime.utc(2026, 9, 13, 12);

Future<KikuyomiDatabase> openSeededDatabase() async {
  final db = KikuyomiDatabase(NativeDatabase.memory());
  await db
      .into(db.sources)
      .insert(
        const SourcesCompanion(
          id: Value(7),
          key: Value('local'),
          name: Value('Local files'),
          lang: Value('und'),
        ),
      );
  return db;
}

Future<int> addBook(
  KikuyomiDatabase db, {
  String key = 'book',
  double? speed,
}) => db
    .into(db.books)
    .insert(
      BooksCompanion(
        sourceId: const Value(7),
        key: Value(key),
        title: const Value('A Book'),
        playbackSpeed: Value(speed),
        createdAt: Value(seedTime),
        updatedAt: Value(seedTime),
      ),
    );

Future<int> addFile(
  KikuyomiDatabase db,
  int bookId,
  String key, {
  int? durationMs,
  bool estimate = false,
  List<TimelineMarker>? markers,
}) => db
    .into(db.mediaFiles)
    .insert(
      MediaFilesCompanion(
        bookId: Value(bookId),
        fileKey: Value(key),
        durationMs: Value(durationMs),
        durationIsEstimate: Value(estimate),
        embeddedMarkers: Value(markers),
      ),
    );

Future<int> addChapter(
  KikuyomiDatabase db,
  int bookId,
  String key,
  int index, {
  bool removed = false,
}) => db
    .into(db.chapters)
    .insert(
      ChaptersCompanion(
        bookId: Value(bookId),
        key: Value(key),
        title: Value(key),
        sourceIndex: Value(index),
        removedFromSource: Value(removed),
        createdAt: Value(seedTime),
        updatedAt: Value(seedTime),
      ),
    );

Future<void> addSegment(
  KikuyomiDatabase db,
  int chapterId,
  int ordinal,
  int fileId, {
  int startMs = 0,
  int? endMs,
}) async {
  await db
      .into(db.chapterSegments)
      .insert(
        ChapterSegmentsCompanion(
          chapterId: Value(chapterId),
          ordinal: Value(ordinal),
          mediaFileId: Value(fileId),
          startMs: Value(startMs),
          endMs: Value(endMs),
        ),
      );
}

Future<void> markRemoved(KikuyomiDatabase db, int chapterId) async {
  await (db.update(db.chapters)..where((c) => c.id.equals(chapterId))).write(
    const ChaptersCompanion(removedFromSource: Value(true)),
  );
}

/// Two chapters of 300 s, one file each, with a remembered speed of 1.25x.
Future<({int book, int c1, int c2})> addTwoChapterBook(
  KikuyomiDatabase db,
) async {
  final book = await addBook(db, speed: 1.25);
  final f1 = await addFile(db, book, 'part1.mp3', durationMs: 300000);
  final f2 = await addFile(db, book, 'part2.mp3', durationMs: 300000);
  final c1 = await addChapter(db, book, 'one', 0);
  final c2 = await addChapter(db, book, 'two', 1);
  await addSegment(db, c1, 0, f1);
  await addSegment(db, c2, 0, f2);
  return (book: book, c1: c1, c2: c2);
}
