import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../merge/book_details.dart';

/// A list of strings stored as a JSON array, such as a book's genres.
final class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) =>
      List.unmodifiable((jsonDecode(fromDb) as List<Object?>).cast<String>());

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

/// The fields a user has edited, stored as a JSON array of field names.
///
/// §4.3 calls `user_overrides` a JSON map. The book row already holds the edited values, so all
/// that needs recording is which fields they are, and a sorted array of names says exactly that.
///
/// A name this version does not recognise, written by a newer version of the app, is skipped rather
/// than failing the whole row. That override is lost the next time this version writes the row,
/// which is an acceptable cost of reading a database from the future.
final class BookFieldSetConverter
    extends TypeConverter<Set<BookField>, String> {
  const BookFieldSetConverter();

  @override
  Set<BookField> fromSql(String fromDb) {
    final known = {for (final field in BookField.values) field.name: field};
    return Set.unmodifiable({
      for (final name in (jsonDecode(fromDb) as List<Object?>).cast<String>())
        ?known[name],
    });
  }

  @override
  String toSql(Set<BookField> value) =>
      jsonEncode([for (final field in value) field.name]..sort());
}

/// Embedded chapter markers probed from a file, stored as a JSON array.
///
/// Stored so that the Timeline can present them as virtual chapters without re-reading the file.
final class MarkerListConverter
    extends TypeConverter<List<TimelineMarker>, String> {
  const MarkerListConverter();

  @override
  List<TimelineMarker> fromSql(String fromDb) => List.unmodifiable([
    for (final entry
        in (jsonDecode(fromDb) as List<Object?>).cast<Map<String, Object?>>())
      TimelineMarker(
        title: entry['title']! as String,
        startMs: entry['startMs']! as int,
      ),
  ]);

  @override
  String toSql(List<TimelineMarker> value) => jsonEncode([
    for (final marker in value)
      {'startMs': marker.startMs, 'title': marker.title},
  ]);
}
