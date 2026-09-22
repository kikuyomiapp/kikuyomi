/// Books as a source describes them: SourceAPI 1.0's `BookSummary` and `BookDetails`.
library;

import '../equality.dart';

/// A book in a list of results, with what a grid or a list row shows.
final class BookSummary {
  BookSummary({
    required this.key,
    required this.title,
    this.coverUrl,
    List<String> authors = const [],
    List<String> narrators = const [],
    this.durationMs,
  }) : authors = List.unmodifiable(authors),
       narrators = List.unmodifiable(narrators);

  /// The book's key, stable across extension updates: with the source, the book's identity (§4.4).
  final String key;
  final String title;
  final Uri? coverUrl;

  /// In credit order. Empty when the source gives none.
  final List<String> authors;

  /// In credit order. Empty when the source gives none.
  final List<String> narrators;

  /// The whole book's length, in milliseconds, when known.
  final int? durationMs;

  @override
  bool operator ==(Object other) =>
      other is BookSummary &&
      other.key == key &&
      other.title == title &&
      other.coverUrl == coverUrl &&
      listEquals(other.authors, authors) &&
      listEquals(other.narrators, narrators) &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(
    key,
    title,
    coverUrl,
    Object.hashAll(authors),
    Object.hashAll(narrators),
    durationMs,
  );

  @override
  String toString() => 'BookSummary($key, "$title")';
}

/// Whether a book is finished, or still being released, as serials are.
enum BookStatus { complete, ongoing, unknown }

/// Who a book is suitable for.
///
/// Declared from the least restrictive to the most, so that the order of [values] is the order of
/// restriction.
enum ContentRating { everyone, mature, adult }

/// The series a book belongs to.
final class Series {
  const Series({required this.name, this.index});

  final String name;

  /// The book's place in the series. Not always whole: a novella between books two and three is
  /// often 2.5.
  final double? index;

  @override
  bool operator ==(Object other) =>
      other is Series && other.name == name && other.index == index;

  @override
  int get hashCode => Object.hash(name, index);

  @override
  String toString() => 'Series("$name"${index == null ? '' : ', $index'})';
}

/// Everything a source says about one book.
///
/// The fields match the source-provided columns of the `book` table and its credits (§4.3), which
/// the §4.4 merge writes them into.
final class BookDetails {
  BookDetails({
    required this.key,
    required this.title,
    this.subtitle,
    List<String> authors = const [],
    List<String> narrators = const [],
    this.series,
    this.description,
    this.coverUrl,
    List<String> genres = const [],
    this.language,
    this.publisher,
    this.publishedDate,
    this.isbn,
    this.abridged,
    this.totalDurationMs,
    this.status = BookStatus.unknown,
    this.contentRating,
    this.webUrl,
  }) : authors = List.unmodifiable(authors),
       narrators = List.unmodifiable(narrators),
       genres = List.unmodifiable(genres);

  final String key;
  final String title;
  final String? subtitle;

  /// In credit order.
  final List<String> authors;

  /// In credit order.
  final List<String> narrators;
  final Series? series;

  /// Plain text, with its line breaks kept.
  final String? description;
  final Uri? coverUrl;
  final List<String> genres;

  /// A BCP 47 language tag, such as `en` or `pt-BR`.
  final String? language;
  final String? publisher;

  /// As the source gives it: `1851`, `1851-10` or `1851-10-18`. Text rather than a date, because
  /// parsing it would invent precision the source never had.
  final String? publishedDate;
  final String? isbn;
  final bool? abridged;

  /// The whole book's length, in milliseconds, when known.
  final int? totalDurationMs;
  final BookStatus status;

  /// Null when the source does not say, which is not the same as [ContentRating.everyone].
  final ContentRating? contentRating;

  /// The book's page on the site, for "open in browser".
  final Uri? webUrl;

  @override
  bool operator ==(Object other) =>
      other is BookDetails &&
      other.key == key &&
      other.title == title &&
      other.subtitle == subtitle &&
      listEquals(other.authors, authors) &&
      listEquals(other.narrators, narrators) &&
      other.series == series &&
      other.description == description &&
      other.coverUrl == coverUrl &&
      listEquals(other.genres, genres) &&
      other.language == language &&
      other.publisher == publisher &&
      other.publishedDate == publishedDate &&
      other.isbn == isbn &&
      other.abridged == abridged &&
      other.totalDurationMs == totalDurationMs &&
      other.status == status &&
      other.contentRating == contentRating &&
      other.webUrl == webUrl;

  @override
  int get hashCode => Object.hashAll([
    key,
    title,
    subtitle,
    Object.hashAll(authors),
    Object.hashAll(narrators),
    series,
    description,
    coverUrl,
    Object.hashAll(genres),
    language,
    publisher,
    publishedDate,
    isbn,
    abridged,
    totalDurationMs,
    status,
    contentRating,
    webUrl,
  ]);

  @override
  String toString() => 'BookDetails($key, "$title")';
}
