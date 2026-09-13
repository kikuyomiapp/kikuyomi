import 'package:drift/drift.dart' hide isNull;
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import '../database/tables.dart';

/// The built-in Local files source (§3.10).
///
/// A fixed id for now. §3 derives source ids from a hash of the extension, source name, language and
/// version, and that scheme arrives with the extension contract in `source_api`. When it does, this
/// constant becomes that hash, by way of a migration.
const localSourceId = 1;

/// One audio file of a local book, as probed from disk.
final class LocalBookFile {
  const LocalBookFile({
    required this.path,
    required this.durationMs,
    this.sizeBytes,
    this.format,
    this.markers = const [],
  });

  /// Where the file is: an absolute path for a file the user keeps, or a path relative to the media
  /// root for a file in the app's own storage, as `LocalMediaResolver` describes. Also the book's
  /// identity within the Local source, so importing the same file twice finds the same book.
  final String path;

  /// Probed from the file itself, so stored as exact rather than estimated.
  final int durationMs;
  final int? sizeBytes;
  final String? format;

  /// Embedded chapter markers, as offsets into the file.
  final List<TimelineMarker> markers;
}

/// A single-file local book to add to the library.
final class LocalBookImport {
  const LocalBookImport({
    required this.file,
    required this.title,
    this.authors = const [],
    this.narrators = const [],
  });

  final LocalBookFile file;
  final String title;
  final List<String> authors;
  final List<String> narrators;
}

/// Adds a single-file local book, such as an M4B, to the library and returns its id.
///
/// It is stored the way §4.5 describes a single file with embedded markers: one source chapter
/// spanning the whole file, with the markers kept on the file so the Timeline presents them as
/// virtual chapters. Progress and bookmarks then anchor to that chapter plus an offset, which stays
/// valid even if the markers are later retagged.
///
/// Importing a file that is already known returns the existing book, putting it back in the library
/// if it had been taken out, so an import can safely be repeated.
///
/// This is a Phase 1 stand-in for the Local source proper, which will implement the extension
/// contract in `source_api` once that contract is designed.
Future<int> importLocalBook(
  KikuyomiDatabase db,
  LocalBookImport book, {
  required Clock clock,
}) {
  final now = clock.now();
  return db.transaction(() async {
    await db
        .into(db.sources)
        .insert(
          const SourcesCompanion(
            id: Value(localSourceId),
            key: Value('local'),
            name: Value('Local files'),
            lang: Value('und'),
          ),
          mode: InsertMode.insertOrIgnore,
        );

    final existing =
        await (db.select(db.books)..where(
              (b) =>
                  b.sourceId.equals(localSourceId) &
                  b.key.equals(book.file.path),
            ))
            .getSingleOrNull();
    if (existing != null) {
      if (!existing.inLibrary) {
        await (db.update(
          db.books,
        )..where((b) => b.id.equals(existing.id))).write(
          BooksCompanion(
            inLibrary: const Value(true),
            dateAdded: Value(now),
            updatedAt: Value(now),
          ),
        );
      }
      return existing.id;
    }

    final bookId = await db
        .into(db.books)
        .insert(
          BooksCompanion(
            sourceId: const Value(localSourceId),
            key: Value(book.file.path),
            title: Value(book.title),
            totalDurationMs: Value(book.file.durationMs),
            inLibrary: const Value(true),
            dateAdded: Value(now),
            detailsFetched: const Value(true),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );

    Future<void> credit(List<String> names, ContributorRole role) async {
      for (var i = 0; i < names.length; i++) {
        final name = names[i].trim();
        if (name.isEmpty) continue;
        await db
            .into(db.people)
            .insert(
              PeopleCompanion(name: Value(name)),
              mode: InsertMode.insertOrIgnore,
            );
        final person = await (db.select(
          db.people,
        )..where((p) => p.name.equals(name))).getSingle();
        await db
            .into(db.bookPeople)
            .insert(
              BookPeopleCompanion(
                bookId: Value(bookId),
                personId: Value(person.id),
                role: Value(role),
                ordinal: Value(i),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    }

    await credit(book.authors, ContributorRole.author);
    await credit(book.narrators, ContributorRole.narrator);

    final fileId = await db
        .into(db.mediaFiles)
        .insert(
          MediaFilesCompanion(
            bookId: Value(bookId),
            fileKey: Value(book.file.path),
            format: Value(book.file.format),
            durationMs: Value(book.file.durationMs),
            durationIsEstimate: const Value(false),
            sizeBytes: Value(book.file.sizeBytes),
            embeddedMarkers: Value(
              book.file.markers.isEmpty ? null : book.file.markers,
            ),
            // A local file is, in §4.3's terms, already downloaded: it is on this device.
            localPath: Value(book.file.path),
          ),
        );

    final chapterId = await db
        .into(db.chapters)
        .insert(
          ChaptersCompanion(
            bookId: Value(bookId),
            key: const Value('whole'),
            title: Value(book.title),
            sourceIndex: const Value(0),
            durationMs: Value(book.file.durationMs),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );

    await db
        .into(db.chapterSegments)
        .insert(
          ChapterSegmentsCompanion(
            chapterId: Value(chapterId),
            ordinal: const Value(0),
            mediaFileId: Value(fileId),
          ),
        );
    return bookId;
  });
}
