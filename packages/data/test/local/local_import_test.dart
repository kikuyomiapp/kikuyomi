import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

const markers = [
  TimelineMarker(title: 'Chapter One', startMs: 0),
  TimelineMarker(title: 'Chapter Two', startMs: 4000),
  TimelineMarker(title: 'Chapter Three', startMs: 9000),
];

LocalBookImport m4b({
  String path = r'C:\Books\A Book.m4b',
  List<TimelineMarker> markers = const [],
  List<String> narrators = const ['A Narrator'],
}) => LocalBookImport(
  file: LocalBookFile(
    path: path,
    durationMs: 15000,
    sizeBytes: 65109,
    format: 'm4b',
    markers: markers,
  ),
  title: 'A Book',
  authors: const ['An Author'],
  narrators: narrators,
);

void main() {
  late KikuyomiDatabase db;
  late FakeClock clock;

  setUp(() {
    db = KikuyomiDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 9, 13, 20));
  });

  tearDown(() => db.close());

  test('adds the book to the library, ready to play', () async {
    final id = await importLocalBook(db, m4b(markers: markers), clock: clock);

    final book = await db.select(db.books).getSingle();
    expect(book.id, id);
    expect(book.inLibrary, isTrue);
    expect(book.title, 'A Book');
    expect(book.totalDurationMs, 15000);
    expect(book.dateAdded!.isAtSameMomentAs(clock.now()), isTrue);

    final stored = await loadStoredPlayback(db, id);
    expect(stored.timeline.chapterIds, hasLength(1));
    expect(stored.timeline.totalDurationMs, 15000);
    expect(stored.timeline.isEstimate, isFalse);
  });

  test('embedded markers become virtual chapters, as §4.5 describes', () async {
    final id = await importLocalBook(db, m4b(markers: markers), clock: clock);
    final navigation = (await loadStoredPlayback(db, id)).timeline.navigation;
    expect(navigation, everyElement(isA<MarkerEntry>()));
    expect(
      [for (final entry in navigation) entry.title],
      ['Chapter One', 'Chapter Two', 'Chapter Three'],
    );
  });

  test('a file without markers is one chapter named after the book', () async {
    final id = await importLocalBook(db, m4b(), clock: clock);
    final navigation = (await loadStoredPlayback(db, id)).timeline.navigation;
    expect(navigation.single, isA<ChapterEntry>());
    expect(navigation.single.title, 'A Book');
  });

  test('credits authors and narrators in their roles', () async {
    await importLocalBook(db, m4b(), clock: clock);
    final credits = await db.select(db.bookPeople).get();
    final people = {
      for (final person in await db.select(db.people).get())
        person.id: person.name,
    };
    expect(
      {for (final c in credits) (people[c.personId], c.role)},
      {
        ('An Author', ContributorRole.author),
        ('A Narrator', ContributorRole.narrator),
      },
    );
  });

  test('importing the same file again finds the same book', () async {
    final first = await importLocalBook(db, m4b(), clock: clock);
    final second = await importLocalBook(db, m4b(), clock: clock);
    expect(second, first);
    expect(await db.select(db.books).get(), hasLength(1));
    expect(await db.select(db.mediaFiles).get(), hasLength(1));
  });

  test('importing a book taken out of the library puts it back', () async {
    final id = await importLocalBook(db, m4b(), clock: clock);
    await (db.update(db.books)..where((b) => b.id.equals(id))).write(
      const BooksCompanion(inLibrary: Value(false)),
    );
    await importLocalBook(db, m4b(), clock: clock);
    expect((await db.select(db.books).getSingle()).inLibrary, isTrue);
  });

  test('a narrator shared by two books is one person', () async {
    await importLocalBook(db, m4b(path: r'C:\Books\One.m4b'), clock: clock);
    await importLocalBook(db, m4b(path: r'C:\Books\Two.m4b'), clock: clock);
    final narrators = await (db.select(
      db.people,
    )..where((p) => p.name.equals('A Narrator'))).get();
    expect(narrators, hasLength(1));
  });
}
