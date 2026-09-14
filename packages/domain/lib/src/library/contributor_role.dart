/// The part a person played in making a book, as §4.3's `book_person.role` records it.
///
/// §4.3 normalises contributors because narrators matter in audiobooks: users filter by them,
/// follow them, and use them to tell editions apart.
///
/// The database stores a role by its name, so a value's name is permanent. A new kind of credit is a
/// new value.
enum ContributorRole { author, narrator }
