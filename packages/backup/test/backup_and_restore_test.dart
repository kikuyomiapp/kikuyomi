import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// A library held in memory, standing in for the database.
final class FakeLibrary implements LibrarySnapshotReader, RestoreWriter {
  FakeLibrary([this.snapshot = const LibrarySnapshot()]);

  final LibrarySnapshot snapshot;

  /// Every plan applied, in order.
  final applied = <RestorePlan>[];

  @override
  Future<LibrarySnapshot> readLibrary() async => snapshot;

  @override
  Future<RestorePlan> restore(
    RestorePlan Function(LibrarySnapshot current) plan,
  ) async {
    final planned = plan(snapshot);
    applied.add(planned);
    return planned;
  }
}

const catalog = SourceSnapshot(
  id: 1,
  key: 'catalog',
  name: 'A Catalog',
  lang: 'en',
);

const browsed = SourceSnapshot(
  id: 2,
  key: 'browsed',
  name: 'Browsed',
  lang: 'en',
);

BookSnapshot stored(
  String key, {
  int sourceId = 1,
  bool inLibrary = false,
  bool started = false,
  List<String> categories = const [],
}) => BookSnapshot(
  sourceId: sourceId,
  key: key,
  details: BookDetailsSnapshot(title: key),
  createdAt: t0,
  updatedAt: t0,
  inLibrary: inLibrary,
  chapters: [
    ChapterSnapshot(
      key: 'one',
      title: 'One',
      sourceIndex: 0,
      createdAt: t0,
      updatedAt: t0,
    ),
  ],
  progress: started
      ? ProgressSnapshot(
          chapterKey: 'one',
          chapterPositionMs: 1000,
          globalPositionMs: 1000,
          updatedAt: t0,
          deviceId: 'this-pc',
        )
      : null,
  categories: categories,
);

void main() {
  group('a backup keeps', () {
    LibrarySnapshot selected() => selectForBackup(
      LibrarySnapshot(
        sources: const [catalog, browsed],
        categories: const [
          CategorySnapshot(name: 'Empty', sortOrder: 0),
          CategorySnapshot(name: 'Next up', sortOrder: 1),
          CategorySnapshot(name: 'Next up', sortOrder: 2),
        ],
        books: [
          stored('in the library', inLibrary: true),
          stored('started, never added', started: true),
          stored('filed, never added', categories: ['Next up']),
          stored('browsed past', sourceId: 2),
        ],
      ),
    );

    test('books in the library, and books outside it that carry user data', () {
      expect(
        [for (final book in selected().books) book.key],
        ['in the library', 'started, never added', 'filed, never added'],
      );
    });

    test('only the sources those books refer to', () {
      expect(selected().sources, [catalog]);
    });

    test('every category, empty ones included, once per name', () {
      expect(
        [for (final c in selected().categories) (c.name, c.sortOrder)],
        [('Empty', 0), ('Next up', 1)],
      );
    });
  });

  test('a backup holds the library, stamped with when and by whom', () async {
    final file = await createBackup(
      FakeLibrary(fullLibrary()),
      clock: FakeClock(at(100)),
      appVersion: '1.2.3',
      deviceId: 'phone',
    );

    final backup = decodeBackup(file);
    expect(backup.info.createdAt, at(100));
    expect(backup.info.appVersion, '1.2.3');
    expect(backup.info.deviceId, 'phone');
    expect(backup.library.books.single.key, '/books/a-book');
  });

  group('restoring', () {
    test(
      'plans against the library the writer reads, and reports what it did',
      () async {
        final library = FakeLibrary();
        final report = await restoreBackup(
          encodeBackup(fullLibrary(), info: info),
          library: library,
        );

        expect(library.applied.single, same(report.plan));
        expect(report.plan.newBooks.single.key, '/books/a-book');
        expect(report.backup.info.deviceId, 'this-pc');
        expect(report.backup.skipped, isEmpty);
      },
    );

    test(
      'a file that cannot be restored from leaves the library untouched',
      () async {
        final library = FakeLibrary();
        final file = encodeBackup(fullLibrary(), info: info);

        await expectLater(
          restoreBackup(file.sublist(0, file.length ~/ 2), library: library),
          throwsA(isA<CorruptBackupException>()),
        );
        expect(library.applied, isEmpty);
      },
    );
  });
}
