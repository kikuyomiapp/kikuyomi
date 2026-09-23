import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart' as api;
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

const sourceId = 0x4c4942;

api.BookDetails theBook = api.BookDetails(
  key: '753',
  title: 'Moby Dick',
  authors: const ['Herman Melville'],
  totalDurationMs: 2400000,
);

final theChapters = [
  api.ChapterInfo(key: 's1', title: 'Loomings', durationMs: 1200000),
  api.ChapterInfo(key: 's2', title: 'The Carpet-Bag', durationMs: 1200000),
];

api.MediaResolution oneFile(
  String name, {
  int? durationMs = 1234567,
  DateTime? expiresAt,
  Map<String, String> headers = const {},
}) => api.MediaResolution(
  expiresAt: expiresAt,
  segments: [
    api.MediaSegment(
      fileKey: name,
      request: api.HttpRequest(
        url: Uri.parse('https://archive.org/download/moby/$name'),
        headers: headers,
      ),
      format: api.MediaFormat.mp3,
      durationMs: durationMs,
      sizeBytes: 9000000,
    ),
  ],
);

void main() {
  late KikuyomiDatabase db;
  late FakeClock clock;
  late Directory mediaRoot;

  setUp(() async {
    db = KikuyomiDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 9, 23, 12));
    mediaRoot = Directory.systemTemp.createTempSync('kikuyomi-media');
    await registerSource(
      db,
      id: sourceId,
      key: 'librivox',
      name: 'LibriVox',
      lang: 'multi',
      extensionId: 'org.kikuyomi.librivox',
    );
  });

  tearDown(() async {
    await db.close();
    if (mediaRoot.existsSync()) mediaRoot.deleteSync(recursive: true);
  });

  SourceMediaResolver resolverFor(api.ContentSource source) =>
      SourceMediaResolver(
        db,
        openSource: (_) async => source,
        onDevice: LocalMediaResolver(db, mediaRoot: mediaRoot),
        clock: clock,
      );

  Future<int> aStreamedBook() async {
    final saved = await saveSourceBook(
      db,
      sourceId: sourceId,
      details: theBook,
      chapters: theChapters,
      clock: clock,
      addToLibrary: true,
    );
    return saved.bookId;
  }

  Future<int> firstFileId(int bookId) async {
    final playback = await loadStoredPlayback(db, bookId);
    return playback.timeline.queue.first.fileId;
  }

  test('asks the source for the chapter the file belongs to', () async {
    final bookId = await aStreamedBook();
    final source = FakeContentSource(media: {'s1': oneFile('moby_001.mp3')});

    final media = await resolverFor(source).resolve(await firstFileId(bookId));

    expect(
      media.uri,
      Uri.parse('https://archive.org/download/moby/moby_001.mp3'),
    );
    final (ref, context) = source.resolutions.single;
    expect(ref.bookKey, '753');
    expect(ref.chapterKey, 's1');
    expect(context.purpose, api.ResolvePurpose.stream);
  });

  test('hands the engine the headers the source asked for (§6.3)', () async {
    final bookId = await aStreamedBook();
    final source = FakeContentSource(
      media: {
        's1': oneFile(
          'moby_001.mp3',
          headers: const {'Referer': 'https://librivox.org/'},
        ),
      },
    );

    final media = await resolverFor(source).resolve(await firstFileId(bookId));

    expect(media.headers, {'Referer': 'https://librivox.org/'});
  });

  test(
    'keeps the estimate\'s row, so the book being played stays playable',
    () async {
      final bookId = await aStreamedBook();
      final fileId = await firstFileId(bookId);
      final source = FakeContentSource(media: {'s1': oneFile('moby_001.mp3')});

      await resolverFor(source).resolve(fileId);

      final file = await (db.select(
        db.mediaFiles,
      )..where((f) => f.id.equals(fileId))).getSingle();
      expect(file.fileKey, 'moby_001.mp3');
      expect(file.format, 'mp3');
      expect(file.sizeBytes, 9000000);
      // §4.5: a source's figure is a claim, not a probe, so it is still an estimate.
      expect(file.durationMs, 1234567);
      expect(file.durationIsEstimate, isTrue);
    },
  );

  test('stores the layout but never the URL (§4.3)', () async {
    final bookId = await aStreamedBook();
    final source = FakeContentSource(
      media: {
        's1': api.MediaResolution(
          segments: [
            api.MediaSegment(
              fileKey: 'moby_whole.m4b',
              request: api.HttpRequest(
                url: Uri.parse('https://archive.org/download/moby/whole.m4b'),
              ),
              range: const api.MediaRange(startMs: 0, endMs: 1200000),
              durationMs: 2400000,
            ),
          ],
        ),
      },
    );

    await resolverFor(source).resolve(await firstFileId(bookId));

    final chapter = await (db.select(
      db.chapters,
    )..where((c) => c.key.equals('s1'))).getSingle();
    final segment = await (db.select(
      db.chapterSegments,
    )..where((s) => s.chapterId.equals(chapter.id))).getSingle();
    expect(segment.startMs, 0);
    expect(segment.endMs, 1200000);
    final files = await db.select(db.mediaFiles).get();
    expect(files.map((f) => f.fileKey), contains('moby_whole.m4b'));
    for (final file in files) {
      expect(file.localPath, isNull);
      expect(file.fileKey, isNot(contains('https://')));
    }
  });

  test('asks again only when the source said the URL had expired', () async {
    final bookId = await aStreamedBook();
    final fileId = await firstFileId(bookId);
    final source = FakeContentSource(
      media: {
        's1': oneFile('moby_001.mp3', expiresAt: DateTime.utc(2026, 9, 23, 13)),
      },
    );
    final resolver = resolverFor(source);

    await resolver.resolve(fileId);
    await resolver.resolve(fileId);
    expect(source.resolutions, hasLength(1));

    clock.advance(const Duration(hours: 2));
    await resolver.resolve(fileId);
    expect(source.resolutions, hasLength(2));
  });

  test(
    're-resolves when the coordinator retries after a stream error',
    () async {
      final bookId = await aStreamedBook();
      final fileId = await firstFileId(bookId);
      final source = FakeContentSource(media: {'s1': oneFile('moby_001.mp3')});
      final resolver = resolverFor(source);

      await resolver.resolve(fileId);
      await resolver.resolve(fileId, refresh: true);

      expect(source.resolutions, hasLength(2));
    },
  );

  test(
    'a chapter that turns out to span two files is laid out on both',
    () async {
      final bookId = await aStreamedBook();
      final fileId = await firstFileId(bookId);
      final source = FakeContentSource(
        media: {
          's1': api.MediaResolution(
            segments: [
              api.MediaSegment(
                fileKey: 'part1.mp3',
                request: api.HttpRequest(
                  url: Uri.parse('https://archive.org/download/moby/part1.mp3'),
                ),
                durationMs: 600000,
              ),
              api.MediaSegment(
                fileKey: 'part2.mp3',
                request: api.HttpRequest(
                  url: Uri.parse('https://archive.org/download/moby/part2.mp3'),
                ),
                durationMs: 600000,
              ),
            ],
          ),
        },
      );

      final media = await resolverFor(source).resolve(fileId);

      expect(media.uri.path, endsWith('part1.mp3'));
      final chapter = (await (db.select(
        db.chapters,
      )..where((c) => c.key.equals('s1'))).getSingle());
      final segments =
          await (db.select(db.chapterSegments)
                ..where((s) => s.chapterId.equals(chapter.id))
                ..orderBy([(s) => OrderingTerm.asc(s.ordinal)]))
              .get();
      expect(segments, hasLength(2));
      // The estimate is consumed by the first file, so nothing is left behind.
      final files = await db.select(db.mediaFiles).get();
      expect(
        files.where((f) => f.bookId == bookId).map((f) => f.fileKey),
        containsAll(['part1.mp3', 'part2.mp3']),
      );
      expect(
        files.any((f) => isEstimatedFileKey(f.fileKey) && f.id == fileId),
        isFalse,
      );
    },
  );

  test(
    'a local book is answered from the device, never from a source',
    () async {
      final file = File('${mediaRoot.path}/book.m4b')..writeAsBytesSync([0]);
      final bookId = await importLocalBook(
        db,
        LocalBookImport(
          file: LocalBookFile(path: file.path, durationMs: 1000),
          title: 'A Local Book',
        ),
        clock: clock,
      );
      final source = FakeContentSource();

      final media = await resolverFor(source)
          .resolve(await firstFileId(bookId));

      expect(media.uri.scheme, 'file');
      expect(source.calls, isEmpty);
    },
  );

  test('a missing local file is reported rather than asked about', () async {
    final bookId = await importLocalBook(
      db,
      LocalBookImport(
        file: LocalBookFile(
          path: '${mediaRoot.path}/gone.m4b',
          durationMs: 1000,
        ),
        title: 'A Local Book',
      ),
      clock: clock,
    );

    await expectLater(
      resolverFor(FakeContentSource()).resolve(await firstFileId(bookId)),
      throwsA(isA<MediaUnavailableException>()),
    );
  });

  test('a source that refuses reaches the caller with its kind', () async {
    final bookId = await aStreamedBook();
    final source = FakeContentSource(
      failure: const api.RateLimitedException(retryAfterMs: 5000),
    );

    await expectLater(
      resolverFor(source).resolve(await firstFileId(bookId)),
      throwsA(isA<api.RateLimitedException>()),
    );
  });
}
