/// The contract's types, as the §4.4 merges take them.
///
/// SourceAPI 1.0's `BookDetails` and `ChapterInfo` are what a source hands the app (§4.1's third
/// model layer); `BookDetails` here and `IncomingChapter` are what the merges work in. This is the
/// boundary between them, and the only place that knows both.
///
/// The contract's package is imported as `api` because both sides call a book's details
/// `BookDetails`. They are not the same type and should not be: one is a source's word, the other
/// is a row's worth of columns.
library;

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart' as api;

import '../merge/book_details.dart';
import '../merge/chapter_sync.dart';
import '../merge/credits.dart';

/// [details] as the §4.4 book-details merge takes them.
///
/// Every field maps straight across but two.
///
/// **`status`.** The contract has three values and the third, `unknown`, is what an unreadable or
/// missing status is read as — "an unknown `status` as `unknown`" — so it means *the source did not
/// say*, not *this book's state is unknown*. Passed on as absent, it falls under the merge's rule
/// that a field the source did not provide keeps its stored value. So a source that once said
/// `complete` and now says nothing leaves the book complete, and a book is never quietly demoted to
/// "unknown" by a flaky refresh. The cost is that a source cannot take a status back once it has
/// given one; that is the same trade the merge already makes for every other field, and no source
/// has ever needed to.
///
/// **`contentRating`.** Null when the source does not say, which is not [api.ContentRating.everyone]
/// (the contract is explicit about this), so null stays null and the stored rating survives.
///
/// Both enumerations are stored by their contract name, which is what the columns hold.
BookDetails toStoredDetails(api.BookDetails details) => BookDetails(
  title: details.title,
  subtitle: details.subtitle,
  description: details.description,
  coverUrl: details.coverUrl?.toString(),
  seriesName: details.series?.name,
  seriesIndex: details.series?.index,
  genres: details.genres,
  language: details.language,
  publisher: details.publisher,
  publishedDate: details.publishedDate,
  isbn: details.isbn,
  abridged: details.abridged,
  status: details.status == api.BookStatus.unknown ? null : details.status.name,
  contentRating: details.contentRating?.name,
  totalDurationMs: details.totalDurationMs,
  webUrl: details.webUrl?.toString(),
);

/// [details]'s credits as the credits merge takes them.
CreditsMerge toCredits(api.BookDetails details) =>
    mergeCredits(authors: details.authors, narrators: details.narrators);

/// [chapters] as chapter synchronisation takes them, in the order the source listed them.
///
/// The contract makes the list's order the book's order, so `source_index` is the position in the
/// list. There is no index to read from a chapter: §3.4's sketch had one and SourceAPI 1.0 took it
/// out, precisely so that two sources cannot disagree with themselves about the order.
List<IncomingChapter> toIncomingChapters(List<api.ChapterInfo> chapters) => [
  for (final (index, chapter) in chapters.indexed)
    IncomingChapter(
      key: chapter.key,
      title: chapter.title,
      sourceIndex: index,
      durationMs: chapter.durationMs,
      publishedAt: chapter.publishedAt,
      group: chapter.group,
    ),
];
