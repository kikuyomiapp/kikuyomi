/// Refreshing a book's details, as docs/architecture.md §4.4 specifies it.
///
/// "When details are refreshed, source-provided fields overwrite stored values except for fields
/// listed in `user_overrides`, and a custom cover always survives." Like chapter sync, the merge is
/// pure: it returns the merged details and what changed, and writes nothing.
library;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// A book's source-provided details. Immutable.
final class BookDetails {
  BookDetails({
    String? title,
    String? subtitle,
    String? description,
    String? coverUrl,
    String? seriesName,
    double? seriesIndex,
    List<String> genres = const [],
    String? language,
    String? publisher,
    String? publishedDate,
    String? isbn,
    bool? abridged,
    String? status,
    String? contentRating,
    int? totalDurationMs,
    String? webUrl,
  }) : _values = Map.unmodifiable(<BookField, Object?>{
         BookField.title: title,
         BookField.subtitle: subtitle,
         BookField.description: description,
         BookField.coverUrl: coverUrl,
         BookField.seriesName: seriesName,
         BookField.seriesIndex: seriesIndex,
         BookField.genres: List<String>.unmodifiable(genres),
         BookField.language: language,
         BookField.publisher: publisher,
         BookField.publishedDate: publishedDate,
         BookField.isbn: isbn,
         BookField.abridged: abridged,
         BookField.status: status,
         BookField.contentRating: contentRating,
         BookField.totalDurationMs: totalDurationMs,
         BookField.webUrl: webUrl,
       });

  BookDetails._(this._values);

  final Map<BookField, Object?> _values;

  String? get title => _values[BookField.title] as String?;
  String? get subtitle => _values[BookField.subtitle] as String?;
  String? get description => _values[BookField.description] as String?;
  String? get coverUrl => _values[BookField.coverUrl] as String?;
  String? get seriesName => _values[BookField.seriesName] as String?;

  /// A double because series positions are not always whole: a novella between books two and three
  /// is often 2.5.
  double? get seriesIndex => _values[BookField.seriesIndex] as double?;

  List<String> get genres => _values[BookField.genres]! as List<String>;
  String? get language => _values[BookField.language] as String?;
  String? get publisher => _values[BookField.publisher] as String?;

  /// Text, not a date. Sources give anything from a bare year to a full timestamp, and parsing it
  /// would invent precision the source never had.
  String? get publishedDate => _values[BookField.publishedDate] as String?;

  String? get isbn => _values[BookField.isbn] as String?;
  bool? get abridged => _values[BookField.abridged] as bool?;
  String? get status => _values[BookField.status] as String?;
  String? get contentRating => _values[BookField.contentRating] as String?;
  int? get totalDurationMs => _values[BookField.totalDurationMs] as int?;
  String? get webUrl => _values[BookField.webUrl] as String?;

  /// The value of [field], for code that treats fields uniformly.
  Object? operator [](BookField field) => _values[field];
}

/// The result of refreshing a book's details.
final class BookDetailsMerge {
  const BookDetailsMerge({required this.details, required this.changedFields});

  final BookDetails details;

  /// Fields whose value differs from what was stored. Empty when the refresh changed nothing, so a
  /// caller can skip the write entirely.
  final Set<BookField> changedFields;

  /// True when the cover URL changed, so the cached cover image has to be fetched again.
  bool get coverChanged => changedFields.contains(BookField.coverUrl);
}

/// Merges freshly fetched [incoming] details over [stored] ones, following §4.4.
///
/// A field keeps its stored value when:
///
/// - it is in [userOverrides], because the user edited it;
/// - it is the cover and [hasCustomCover] is true, because a custom cover always survives;
/// - the source did not provide it this time: null, a blank string, or an empty list.
///
/// The last rule is a choice §4.4 leaves open, made to match chapter synchronisation, where a source
/// that stops reporting a duration does not erase it. Sources drop fields far more often through
/// flakiness or partial responses than through deliberate removal, and a refresh that silently
/// deletes a book's description is worse than one that occasionally keeps a stale one. Values that
/// are present but falsy, such as `abridged: false`, are real values and do overwrite.
BookDetailsMerge mergeBookDetails({
  required BookDetails stored,
  required BookDetails incoming,
  Set<BookField> userOverrides = const {},
  bool hasCustomCover = false,
}) {
  final merged = <BookField, Object?>{};
  final changed = <BookField>{};

  for (final field in BookField.values) {
    final keepStored =
        userOverrides.contains(field) ||
        (field == BookField.coverUrl && hasCustomCover) ||
        _absent(incoming[field]);
    final value = keepStored ? stored[field] : incoming[field];
    merged[field] = value;
    if (!_same(value, stored[field])) changed.add(field);
  }

  return BookDetailsMerge(
    details: BookDetails._(Map.unmodifiable(merged)),
    changedFields: Set.unmodifiable(changed),
  );
}

bool _absent(Object? value) =>
    value == null ||
    (value is String && value.trim().isEmpty) ||
    (value is List && value.isEmpty);

bool _same(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
  return a == b;
}
