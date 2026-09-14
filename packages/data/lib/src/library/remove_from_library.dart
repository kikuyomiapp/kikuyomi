import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';

/// Takes book [bookId] out of the library.
///
/// Only the book's place in the library changes. Its progress, listening history, bookmarks,
/// chapters and file layout all stay, and no file on disk is touched. That follows §4.4, which
/// never lets a refresh throw away what carries user data, and it means adding the book again
/// brings it back where the listener left off: the local import already puts a book it finds taken
/// out back in the library rather than adding it anew.
///
/// Leaving the library also takes the book off Continue Listening, which lists library books only.
///
/// Does nothing for a book that does not exist.
Future<void> removeBookFromLibrary(
  KikuyomiDatabase db,
  int bookId, {
  required Clock clock,
}) async {
  await (db.update(db.books)..where((b) => b.id.equals(bookId))).write(
    BooksCompanion(
      inLibrary: const Value(false),
      updatedAt: Value(clock.now()),
    ),
  );
}
