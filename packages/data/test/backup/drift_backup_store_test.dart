import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

import 'library_fixtures.dart';

Future<List<int>> backUp(KikuyomiDatabase db) => createBackup(
  DriftBackupStore(db),
  clock: FakeClock(DateTime.utc(2026, 9, 2)),
  appVersion: '0.1.0+1',
  deviceId: 'this-pc',
);

Future<RestoreReport> restoreInto(KikuyomiDatabase db, List<int> file) =>
    restoreBackup(file, library: DriftBackupStore(db));

void main() {
  // Each test opens two databases, the one backed up and the one restored into, each on its own
  // in-memory executor. Drift's warning is about two databases sharing one executor, not this.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late KikuyomiDatabase original;
  late KikuyomiDatabase restored;

  setUp(() async {
    original = openDatabase();
    restored = openDatabase();
    await seedLibrary(original);
  });

  tearDown(() async {
    await original.close();
    await restored.close();
  });

  group('into a fresh database', () {
    test('a library comes back column for column, apart from what backups leave out', () async {
      final report = await restoreInto(restored, await backUp(original));
      expect(report.backup.skipped, isEmpty);

      // Left out on purpose: the book only browsed past, the source only it used, and the cached
      // cover image.
      await (original.delete(
        original.books,
      )..where((b) => b.key.equals('browsed'))).go();
      await (original.delete(
        original.sources,
      )..where((s) => s.id.equals(browsedSourceId))).go();
      await original
          .update(original.books)
          .write(
            const BooksCompanion(
              coverLocalPath: Value(null),
              coverUpdatedAt: Value(null),
            ),
          );

      expect(await dumpLibrary(restored), await dumpLibrary(original));
    });

    test(
      'a restored book plays on from where it was left, at its speed',
      () async {
        await restoreInto(restored, await backUp(original));

        final book = await bookByKey(restored, aBook);
        final two = await chapterByKey(restored, book.id, 'two');
        final playback = await loadStoredPlayback(restored, book.id);
        expect(
          playback.resumeFrom,
          ChapterPosition(chapterId: two.id, offsetMs: 12345),
        );
        expect(playback.speed, 1.25);
        expect(playback.timeline.chapterIds, hasLength(2));
      },
    );

    test('the restored library backs up to the same file', () async {
      await restoreInto(restored, await backUp(original));
      expect(await backUp(restored), await backUp(original));
    });

    test('restoring the same backup again changes nothing', () async {
      final file = await backUp(original);
      await restoreInto(restored, file);
      final before = await dumpLibrary(restored);

      final again = await restoreInto(restored, file);
      expect(again.plan.isEmpty, isTrue);
      expect(await dumpLibrary(restored), before);
    });
  });

  group('into a library already in use', () {
    test(
      'merges into the books it has, adds the rest, and duplicates nothing',
      () async {
        await restored
            .into(restored.sources)
            .insert(
              const SourcesCompanion(
                id: Value(localSourceId),
                key: Value('local'),
                name: Value('Local files'),
                lang: Value('und'),
              ),
            );
        for (final (name, sortOrder) in [('Mine', 0), ('Next up', 1)]) {
          await restored
              .into(restored.categories)
              .insert(
                CategoriesCompanion(
                  name: Value(name),
                  sortOrder: Value(sortOrder),
                ),
              );
        }
        await restored
            .into(restored.books)
            .insert(
              BooksCompanion(
                sourceId: const Value(localSourceId),
                key: const Value('mine'),
                title: const Value('My Own Book'),
                inLibrary: const Value(true),
                createdAt: Value(at(500)),
                updatedAt: Value(at(500)),
              ),
            );
        // The started book, added here since, but not yet played.
        await addStartedBook(restored, updatedAt: at(500), inLibrary: true);

        await restoreInto(restored, await backUp(original));

        final books = await restored.select(restored.books).get();
        expect({for (final b in books) b.key}, {aBook, startedBook, 'mine'});

        final started = await bookByKey(restored, startedBook);
        expect(started.inLibrary, isTrue);
        final whole = await chapterByKey(restored, started.id, 'whole');
        expect(
          (await loadStoredPlayback(restored, started.id)).resumeFrom,
          ChapterPosition(chapterId: whole.id, offsetMs: 5000),
        );
        expect(
          await restored.select(restored.chapters).get(),
          hasLength(4),
          reason:
              'three chapters of the restored book, one of the started book',
        );

        final categories = await (restored.select(
          restored.categories,
        )..orderBy([(c) => OrderingTerm.asc(c.sortOrder)])).get();
        expect(
          [for (final c in categories) (c.name, c.sortOrder)],
          [('Mine', 0), ('Next up', 1), ('Empty', 2)],
        );
        final restoredBook = await bookByKey(restored, aBook);
        final membership = await (restored.select(
          restored.bookCategories,
        )..where((m) => m.bookId.equals(restoredBook.id))).getSingle();
        expect(membership.categoryId, categories[1].id);
      },
    );

    test('newer progress here is not overwritten by an older backup', () async {
      final file = await backUp(original);
      await restoreInto(restored, file);

      // Listening goes on here after the backup was taken.
      final book = await bookByKey(restored, aBook);
      final one = await chapterByKey(restored, book.id, 'one');
      await DriftPlaybackStore(
        restored,
        deviceId: 'this-pc',
        clock: FakeClock(at(900)),
      ).saveProgress(
        bookId: book.id,
        position: ChapterPosition(chapterId: one.id, offsetMs: 1000),
        globalMs: 1000,
      );

      final report = await restoreInto(restored, file);
      expect(report.plan.isEmpty, isTrue);
      expect(
        (await loadStoredPlayback(restored, book.id)).resumeFrom,
        ChapterPosition(chapterId: one.id, offsetMs: 1000),
      );
      final chapter = await chapterByKey(restored, book.id, 'one');
      expect(chapter.lastPositionMs, 1000);
    });

    test('newer progress in a backup replaces older progress here', () async {
      await restoreInto(restored, await backUp(original));

      // Listening goes on on the original device, which backs up again.
      final book = await bookByKey(original, aBook);
      final one = await chapterByKey(original, book.id, 'one');
      await DriftPlaybackStore(
        original,
        deviceId: 'phone',
        clock: FakeClock(at(900)),
      ).saveProgress(
        bookId: book.id,
        position: ChapterPosition(chapterId: one.id, offsetMs: 2000),
        globalMs: 2000,
      );
      await restoreInto(restored, await backUp(original));

      final here = await bookByKey(restored, aBook);
      final oneHere = await chapterByKey(restored, here.id, 'one');
      expect(
        (await loadStoredPlayback(restored, here.id)).resumeFrom,
        ChapterPosition(chapterId: oneHere.id, offsetMs: 2000),
      );
      expect(oneHere.lastPositionMs, 2000);
      final state = await restored.select(restored.playbackStates).get();
      expect(
        {for (final s in state) s.deviceId},
        {'phone', 'this-pc'},
        reason: 'the book progressed on the phone; the started book did not',
      );
    });

    test(
      'a book imported again before restoring gets its progress back',
      () async {
        const file = LocalBookFile(
          path: r'C:\Books\Again.m4b',
          durationMs: 60000,
        );
        const again = LocalBookImport(file: file, title: 'Again');
        final before = openDatabase();
        addTearDown(before.close);
        final id = await importLocalBook(
          before,
          again,
          clock: FakeClock(at(0)),
        );
        final whole = await chapterByKey(before, id, 'whole');
        await DriftPlaybackStore(
          before,
          deviceId: 'this-pc',
          clock: FakeClock(at(10)),
        ).saveProgress(
          bookId: id,
          position: ChapterPosition(chapterId: whole.id, offsetMs: 42000),
          globalMs: 42000,
        );
        final backup = await backUp(before);

        // After a reinstall, the book is added again before the backup is restored, so its chapter is
        // newer than the backup's and has nothing listened.
        final idHere = await importLocalBook(
          restored,
          again,
          clock: FakeClock(at(1000)),
        );
        await restoreInto(restored, backup);

        final wholeHere = await chapterByKey(restored, idHere, 'whole');
        expect(
          (await loadStoredPlayback(restored, idHere)).resumeFrom,
          ChapterPosition(chapterId: wholeHere.id, offsetMs: 42000),
        );
        expect(wholeHere.lastPositionMs, 42000);
      },
    );
  });

  group('a file that cannot be restored from', () {
    test(
      'when corrupt or cut short, is reported and leaves the library as it was',
      () async {
        final file = await backUp(original);
        await restoreInto(restored, await backUp(original));
        await (restored.delete(
          restored.bookmarks,
        )..where((b) => b.positionMs.equals(5))).go();
        final before = await dumpLibrary(restored);

        await expectLater(
          restoreInto(restored, file.sublist(0, file.length - 10)),
          throwsA(isA<CorruptBackupException>()),
        );
        final damaged = [...file]..[file.length ~/ 2] ^= 0xff;
        await expectLater(
          restoreInto(restored, damaged),
          throwsA(isA<CorruptBackupException>()),
        );
        expect(await dumpLibrary(restored), before);
      },
    );

    test('when from a newer format this build cannot restore, is refused saying so', () async {
      final file = await backUp(original);
      // Protobuf keeps the last value it reads for a field, so appending min_reader_version (field 2,
      // a varint) makes the backup demand a newer reader than this build.
      final future = gzip.encode([...gzip.decode(file), 0x10, 0x02]);

      await expectLater(
        restoreInto(restored, future),
        throwsA(
          isA<UnsupportedBackupVersionException>().having(
            (e) => e.message,
            'message',
            contains('format version 2'),
          ),
        ),
      );
      expect(await restored.select(restored.books).get(), isEmpty);
    });
  });

  test(
    'edited fields and credit roles have the same names in both packages',
    () {
      expect(
        [for (final field in BookField.values) field.name],
        [for (final field in BookDetailField.values) field.name],
      );
      expect(
        [for (final role in ContributorRole.values) role.name],
        [for (final role in CreditRole.values) role.name],
      );
    },
  );
}
