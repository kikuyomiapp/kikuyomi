/// Which books in the library are still waiting for the cover their source named.
///
/// A local book's cover comes out of its own files (`local_covers.dart`); a source book's is a URL,
/// so somebody has to fetch it. Fetching belongs to the app — this package holds no transport — so
/// what is here is the question "which books still need one", asked the same way the local search
/// asks it, and the answer is kept with the same `keepBookCover`.
library;

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';
import '../local/local_import.dart' show localSourceId;

/// A book in the library whose cover has been named but never fetched.
final class BookAwaitingCover {
  const BookAwaitingCover({
    required this.bookId,
    required this.sourceId,
    required this.title,
    required this.coverUrl,
  });

  final int bookId;

  /// Which source to ask how to fetch it: a source that declares `getImageRequest` may need headers
  /// or cookies on the request (§6.3).
  final int sourceId;
  final String title;
  final Uri coverUrl;
}

/// The books in the library from a source, with a cover URL, whose cover has never been fetched, the
/// most recently added first.
///
/// A book whose cover has been looked for is never looked at again, whether or not one was found, so
/// this empties as covers arrive. Local books are left out: theirs come from their files. A book out
/// of the library is left alone, as the local search leaves one, so a removed book costs nothing at
/// every start.
Future<List<BookAwaitingCover>> booksAwaitingSourceCover(
  KikuyomiDatabase db, {
  int limit = 200,
}) async {
  final books =
      await (db.select(db.books)
            ..where(
              (b) =>
                  b.sourceId.equals(localSourceId).not() &
                  b.inLibrary.equals(true) &
                  b.coverUrl.isNotNull() &
                  b.coverUpdatedAt.isNull() &
                  b.coverLocalPath.isNull(),
            )
            ..orderBy([(b) => OrderingTerm.desc(b.id)])
            ..limit(limit))
          .get();
  return [
    for (final book in books)
      if (!book.userOverrides.contains(BookField.coverUrl))
        if (_url(book.coverUrl) case final Uri url)
          BookAwaitingCover(
            bookId: book.id,
            sourceId: book.sourceId,
            title: book.title,
            coverUrl: url,
          ),
  ];
}

/// A stored cover URL, or null when it is not one the app can fetch.
///
/// Stored URLs come from a source and have already passed the contract's URL rule, but a row can
/// also come from a backup written by another version, so it is read rather than trusted.
Uri? _url(String? stored) {
  if (stored == null) return null;
  final url = Uri.tryParse(stored);
  if (url == null || !url.hasScheme || !url.hasAuthority) return null;
  return url.scheme == 'http' || url.scheme == 'https' ? url : null;
}
