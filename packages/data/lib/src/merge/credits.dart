/// A book's credits, as docs/architecture.md §4.3 and §4.4 have them.
///
/// §4.3 normalises contributors into `person` and `book_person` "because narrators matter far more
/// in audiobooks than illustrators do in manga: users filter by narrator, follow narrators, and use
/// narrator to tell editions apart". §4.4 then says a refresh overwrites source-provided fields, and
/// credits are source-provided.
///
/// The planner here is pure, as the other two merges are: it says what a book's credits should be,
/// and writing them is [applyCredits]'s work.
library;

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';

/// One line of a book's credits: who, as what, and where in the list.
final class Credit {
  const Credit({required this.name, required this.role, required this.ordinal});

  /// The person's name as the source writes it, trimmed and with runs of whitespace collapsed.
  final String name;
  final ContributorRole role;

  /// Credit order within the role, from zero.
  final int ordinal;

  @override
  bool operator ==(Object other) =>
      other is Credit &&
      other.name == name &&
      other.role == role &&
      other.ordinal == ordinal;

  @override
  int get hashCode => Object.hash(name, role, ordinal);

  @override
  String toString() => 'Credit("$name", ${role.name}, $ordinal)';
}

/// What a book's credits should become.
final class CreditsMerge {
  const CreditsMerge({required this.credits, required this.roles});

  /// Every credit to keep, authors first and then narrators, each in credit order.
  final List<Credit> credits;

  /// The roles this merge decides. A role the source said nothing about this time is not here, and
  /// its stored credits are left exactly as they are.
  final Set<ContributorRole> roles;

  /// The credits of one role, in credit order.
  List<Credit> of(ContributorRole role) => [
    for (final credit in credits)
      if (credit.role == role) credit,
  ];
}

/// Plans a book's credits from what a source gave: [authors] and [narrators], each in credit order.
///
/// The rules, and why:
///
/// - **A name is trimmed and its inner whitespace collapsed.** Sources write `"Herman  Melville"`
///   and `" Melville"` for one person, and `person.name` is unique, so two spellings of one name
///   would otherwise become two people to filter by.
/// - **Empty names are left out**, never stored. A source that credits `""` has credited nobody.
/// - **A name repeated within a role keeps its first place.** The primary key of `book_person` is
///   `{book_id, person_id, role}`, so the same person cannot hold two ordinals in one role; the
///   first mention is the one the source meant. Ordinals are then dense, counting the kept names,
///   so a duplicate never leaves a gap in the credit order.
/// - **The same name in both roles is two credits.** An author who reads their own book is common
///   in audiobooks, and the key allows it.
/// - **A role the source left empty is not decided here.** It is absent from [CreditsMerge.roles],
///   and [applyCredits] leaves what is stored alone. This is the rule `mergeBookDetails` applies to
///   every other field, made for the same reason: sources drop a field through flakiness far more
///   often than through deliberate removal, and a refresh that silently forgets who read a book is
///   worse than one that keeps a stale list.
///
/// Names are compared exactly, not folded for case: they are proper nouns, and a source that writes
/// `de la Mare` one way and `De La Mare` another has given two spellings the app has no business
/// deciding between.
CreditsMerge mergeCredits({
  List<String> authors = const [],
  List<String> narrators = const [],
}) {
  final credits = <Credit>[];
  final roles = <ContributorRole>{};

  void add(List<String> names, ContributorRole role) {
    final kept = <String>[];
    for (final name in names) {
      final tidy = name.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (tidy.isEmpty || kept.contains(tidy)) continue;
      kept.add(tidy);
    }
    if (kept.isEmpty) return;
    roles.add(role);
    for (var i = 0; i < kept.length; i++) {
      credits.add(Credit(name: kept[i], role: role, ordinal: i));
    }
  }

  add(authors, ContributorRole.author);
  add(narrators, ContributorRole.narrator);
  return CreditsMerge(
    credits: List.unmodifiable(credits),
    roles: Set.unmodifiable(roles),
  );
}

/// Writes [merge] as the credits of book [bookId].
///
/// People are inserted as they are met and never removed: `person` is shared between books, and a
/// narrator who leaves one book's credits is still the narrator of every other. Only the book's own
/// `book_person` rows are replaced, and only for the roles [merge] decided.
///
/// Runs inside the caller's transaction when there is one, so a half-written credit list is never
/// visible.
Future<void> applyCredits(
  KikuyomiDatabase db,
  int bookId,
  CreditsMerge merge,
) async {
  if (merge.roles.isEmpty) return;
  final ids = <String, int>{};
  for (final credit in merge.credits) {
    if (ids.containsKey(credit.name)) continue;
    await db
        .into(db.people)
        .insert(
          PeopleCompanion(name: Value(credit.name)),
          mode: InsertMode.insertOrIgnore,
        );
    final person = await (db.select(
      db.people,
    )..where((p) => p.name.equals(credit.name))).getSingle();
    ids[credit.name] = person.id;
  }

  await (db.delete(db.bookPeople)..where(
        (c) =>
            c.bookId.equals(bookId) &
            c.role.isInValues(merge.roles.toList(growable: false)),
      ))
      .go();
  for (final credit in merge.credits) {
    await db
        .into(db.bookPeople)
        .insert(
          BookPeopleCompanion(
            bookId: Value(bookId),
            personId: Value(ids[credit.name]!),
            role: Value(credit.role),
            ordinal: Value(credit.ordinal),
          ),
        );
  }
}
