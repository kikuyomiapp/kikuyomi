import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:test/test.dart';

void main() {
  group('planning a book\'s credits', () {
    test('keeps each role in the order the source credited it', () {
      final merge = mergeCredits(
        authors: ['Herman Melville'],
        narrators: ['Stewart Wills', 'Kristin LeMoine'],
      );

      expect(merge.of(ContributorRole.author), [
        const Credit(
          name: 'Herman Melville',
          role: ContributorRole.author,
          ordinal: 0,
        ),
      ]);
      expect(merge.of(ContributorRole.narrator).map((c) => c.name), [
        'Stewart Wills',
        'Kristin LeMoine',
      ]);
      expect(merge.of(ContributorRole.narrator).map((c) => c.ordinal), [0, 1]);
    });

    test('trims a name and collapses the whitespace inside it', () {
      final merge = mergeCredits(authors: ['  Herman   Melville ']);

      expect(merge.credits.single.name, 'Herman Melville');
    });

    test('leaves out an empty name rather than storing one', () {
      final merge = mergeCredits(authors: ['', '   ', 'Various']);

      expect(merge.credits.map((c) => c.name), ['Various']);
      expect(merge.credits.single.ordinal, 0);
    });

    test('drops a name repeated within a role and leaves no gap after it', () {
      // The key of book_person is {book, person, role}, so one person cannot hold two ordinals in
      // one role. Dense ordinals keep the credit order readable.
      final merge = mergeCredits(
        narrators: ['David Wales', 'David Wales', 'Ruth Golding'],
      );

      expect(merge.of(ContributorRole.narrator).map((c) => c.name), [
        'David Wales',
        'Ruth Golding',
      ]);
      expect(merge.of(ContributorRole.narrator).map((c) => c.ordinal), [0, 1]);
    });

    test('credits one person twice when they wrote the book and read it', () {
      final merge = mergeCredits(
        authors: ['Mark Twain'],
        narrators: ['Mark Twain'],
      );

      expect(merge.credits.length, 2);
      expect(merge.roles, {ContributorRole.author, ContributorRole.narrator});
    });

    test('decides nothing about a role the source left empty', () {
      final merge = mergeCredits(authors: ['Herman Melville']);

      expect(merge.roles, {ContributorRole.author});
    });
  });

  group('writing a book\'s credits', () {
    late KikuyomiDatabase db;

    setUp(() => db = KikuyomiDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<int> aBook() async {
      await db
          .into(db.sources)
          .insert(
            const SourcesCompanion(
              id: Value(7),
              key: Value('librivox'),
              name: Value('LibriVox'),
              lang: Value('multi'),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      final now = DateTime.utc(2026, 9, 23);
      return db
          .into(db.books)
          .insert(
            BooksCompanion(
              sourceId: const Value(7),
              key: const Value('753'),
              title: const Value('Moby Dick'),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
    }

    Future<List<(String, ContributorRole, int)>> creditsOf(int bookId) async {
      final rows =
          await (db.select(db.bookPeople).join([
                  innerJoin(
                    db.people,
                    db.people.id.equalsExp(db.bookPeople.personId),
                  ),
                ])
                ..where(db.bookPeople.bookId.equals(bookId))
                ..orderBy([
                  OrderingTerm.asc(db.bookPeople.role),
                  OrderingTerm.asc(db.bookPeople.ordinal),
                ]))
              .get();
      return [
        for (final row in rows)
          (
            row.readTable(db.people).name,
            row.readTable(db.bookPeople).role,
            row.readTable(db.bookPeople).ordinal,
          ),
      ];
    }

    test('writes people once and credits them in order', () async {
      final bookId = await aBook();

      await applyCredits(
        db,
        bookId,
        mergeCredits(
          authors: ['Herman Melville'],
          narrators: ['Stewart Wills', 'Herman Melville'],
        ),
      );

      expect(await creditsOf(bookId), [
        ('Herman Melville', ContributorRole.author, 0),
        ('Stewart Wills', ContributorRole.narrator, 0),
        ('Herman Melville', ContributorRole.narrator, 1),
      ]);
      expect(await db.select(db.people).get(), hasLength(2));
    });

    test('a refresh replaces the roles it decides', () async {
      final bookId = await aBook();
      await applyCredits(
        db,
        bookId,
        mergeCredits(authors: ['A Mistake'], narrators: ['Stewart Wills']),
      );

      await applyCredits(
        db,
        bookId,
        mergeCredits(
          authors: ['Herman Melville'],
          narrators: ['Stewart Wills'],
        ),
      );

      expect(await creditsOf(bookId), [
        ('Herman Melville', ContributorRole.author, 0),
        ('Stewart Wills', ContributorRole.narrator, 0),
      ]);
    });

    test('a refresh that says nothing about a role keeps it', () async {
      final bookId = await aBook();
      await applyCredits(
        db,
        bookId,
        mergeCredits(
          authors: ['Herman Melville'],
          narrators: ['Stewart Wills'],
        ),
      );

      await applyCredits(
        db,
        bookId,
        mergeCredits(authors: ['Herman Melville']),
      );

      expect(await creditsOf(bookId), [
        ('Herman Melville', ContributorRole.author, 0),
        ('Stewart Wills', ContributorRole.narrator, 0),
      ]);
    });

    test('a person stays known to other books after losing a credit', () async {
      final bookId = await aBook();
      await applyCredits(db, bookId, mergeCredits(narrators: ['David Wales']));

      await applyCredits(db, bookId, mergeCredits(narrators: ['Ruth Golding']));

      expect(await creditsOf(bookId), [
        ('Ruth Golding', ContributorRole.narrator, 0),
      ]);
      expect(
        (await db.select(db.people).get()).map((p) => p.name),
        containsAll(['David Wales', 'Ruth Golding']),
      );
    });
  });
}
