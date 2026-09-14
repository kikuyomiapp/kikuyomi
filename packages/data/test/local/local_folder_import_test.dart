import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

const threeTracks = [
  LocalTrackImport(
    file: LocalBookFile(
      path: r'C:\Books\A Book\01.mp3',
      durationMs: 60000,
      format: 'mp3',
    ),
    title: 'Opening',
  ),
  LocalTrackImport(
    file: LocalBookFile(
      path: r'C:\Books\A Book\02.mp3',
      durationMs: 90000,
      format: 'mp3',
    ),
    title: 'Middle',
  ),
  LocalTrackImport(
    file: LocalBookFile(
      path: r'C:\Books\A Book\03.mp3',
      durationMs: 30000,
      format: 'mp3',
    ),
    title: 'End',
  ),
];

LocalFolderImport folder({List<LocalTrackImport> tracks = threeTracks}) =>
    LocalFolderImport(
      key: r'C:\Books\A Book',
      title: 'A Book',
      authors: const ['An Author'],
      narrators: const ['A Narrator'],
      tracks: tracks,
    );

void main() {
  late KikuyomiDatabase db;
  late FakeClock clock;

  setUp(() {
    db = KikuyomiDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 9, 14, 12));
  });

  tearDown(() => db.close());

  test('makes each file a chapter, in the order given', () async {
    final id = await importLocalFolderBook(db, folder(), clock: clock);

    final book = await db.select(db.books).getSingle();
    expect(book.id, id);
    expect(book.title, 'A Book');
    expect(book.inLibrary, isTrue);
    expect(book.totalDurationMs, 180000);

    final timeline = (await loadStoredPlayback(db, id)).timeline;
    expect(
      [for (final entry in timeline.navigation) entry.title],
      ['Opening', 'Middle', 'End'],
    );
    expect(timeline.queue, hasLength(3));
    expect(timeline.totalDurationMs, 180000);
    expect(timeline.isEstimate, isFalse);
  });

  test('stores where each file is, for the resolver to find', () async {
    await importLocalFolderBook(db, folder(), clock: clock);
    final files = await db.select(db.mediaFiles).get();
    expect(
      {for (final file in files) file.localPath},
      {
        r'C:\Books\A Book\01.mp3',
        r'C:\Books\A Book\02.mp3',
        r'C:\Books\A Book\03.mp3',
      },
    );
  });

  test('keeps an estimated duration an estimate', () async {
    final id = await importLocalFolderBook(
      db,
      folder(
        tracks: const [
          LocalTrackImport(
            file: LocalBookFile(
              path: 'Import/A Book/01.mp3',
              durationMs: 60000,
              durationIsEstimate: true,
            ),
            title: 'Opening',
          ),
        ],
      ),
      clock: clock,
    );
    expect((await loadStoredPlayback(db, id)).timeline.isEstimate, isTrue);
  });

  test('credits authors and narrators', () async {
    await importLocalFolderBook(db, folder(), clock: clock);
    final people = await db.select(db.people).get();
    expect(
      {for (final person in people) person.name},
      {'An Author', 'A Narrator'},
    );
  });

  test('importing the same folder again finds the same book', () async {
    final first = await importLocalFolderBook(db, folder(), clock: clock);
    final second = await importLocalFolderBook(db, folder(), clock: clock);
    expect(second, first);
    expect(await db.select(db.books).get(), hasLength(1));
    expect(await db.select(db.mediaFiles).get(), hasLength(3));
  });

  test('a folder with no tracks is refused', () async {
    expect(
      importLocalFolderBook(db, folder(tracks: const []), clock: clock),
      throwsArgumentError,
    );
  });
}
