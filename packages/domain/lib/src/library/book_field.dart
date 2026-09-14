/// The book fields a source provides and a user can edit.
///
/// These mirror the source-provided columns of the `book` table in §4.3. Authors and narrators are
/// credits rather than fields, and merge separately.
///
/// §4.4 keeps a user's edits through every refresh from the source, which takes recording which
/// fields were edited. The database stores that set by field name, and so do backups, so a field's
/// name is permanent: renaming one would quietly forget every edit to it, in the library and in every
/// backup written before.
enum BookField {
  title,
  subtitle,
  description,
  coverUrl,
  seriesName,
  seriesIndex,
  genres,
  language,
  publisher,
  publishedDate,
  isbn,
  abridged,
  status,
  contentRating,
  totalDurationMs,
  webUrl,
}
