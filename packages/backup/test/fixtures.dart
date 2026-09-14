// Libraries and backup metadata shared by the tests.

import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

final t0 = DateTime.utc(2026, 9, 1, 12);

/// [minutes] after [t0], with milliseconds, so that a codec rounding to seconds shows up.
DateTime at(int minutes) =>
    t0.add(Duration(minutes: minutes, milliseconds: 250));

final info = BackupInfo(
  createdAt: at(600),
  appVersion: '0.1.0+1',
  deviceId: 'this-pc',
);

/// A library in which every field of the format holds something other than its default, so that a
/// field the codec forgets to write shows up as unset.
LibrarySnapshot fullLibrary() => LibrarySnapshot(
  sources: [
    SourceSnapshot(
      // Negative, to exercise all 64 bits of a hashed id.
      id: -4242424242424242424,
      extensionId: 'org.example.catalog',
      key: 'catalog',
      name: 'A Catalog',
      lang: 'en',
      contentRating: 'everyone',
      isEnabled: true,
      isPinned: true,
      lastUsedAt: at(1),
    ),
  ],
  categories: const [CategorySnapshot(name: 'Next up', sortOrder: 3, flags: 5)],
  books: [
    BookSnapshot(
      sourceId: -4242424242424242424,
      key: '/books/a-book',
      details: BookDetailsSnapshot(
        title: 'A Book',
        subtitle: 'A Subtitle',
        description: 'A description.',
        coverUrl: 'https://example.org/cover.jpg',
        seriesName: 'A Series',
        seriesIndex: 2.5,
        genres: const ['Fiction', 'Classics'],
        language: 'en',
        publisher: 'A Publisher',
        publishedDate: '1900',
        isbn: '0000000000',
        abridged: true,
        status: 'complete',
        contentRating: 'everyone',
        totalDurationMs: 600000,
        webUrl: 'https://example.org/a-book',
      ),
      userOverrides: const {BookDetailField.title, BookDetailField.coverUrl},
      contributors: const [
        ContributorSnapshot(
          name: 'An Author',
          role: CreditRole.author,
          ordinal: 1,
        ),
      ],
      inLibrary: true,
      dateAdded: at(2),
      lastRefreshedAt: at(3),
      detailsFetched: true,
      playbackSpeed: 1.25,
      createdAt: at(4),
      updatedAt: at(5),
      mediaFiles: [
        MediaFileSnapshot(
          fileKey: 'part1.mp3',
          format: 'mp3',
          durationMs: 300000,
          durationIsEstimate: true,
          sizeBytes: 4800000,
          embeddedMarkers: const [
            TimelineMarker(title: 'Opening', startMs: 500),
            TimelineMarker(title: 'Middle', startMs: 150000),
          ],
          localPath: 'Import/part1.mp3',
          downloadedAt: at(6),
        ),
      ],
      chapters: [
        ChapterSnapshot(
          key: 'one',
          title: 'Chapter One',
          sourceIndex: 1,
          groupName: 'Part One',
          durationMs: 290000,
          publishedAt: at(7),
          isListened: true,
          listenedAt: at(8),
          lastPositionMs: 12345,
          removedFromSource: true,
          createdAt: at(9),
          updatedAt: at(10),
          segments: const [
            SegmentSnapshot(fileKey: 'part1.mp3', startMs: 1000, endMs: 291000),
          ],
        ),
      ],
      progress: ProgressSnapshot(
        chapterKey: 'one',
        chapterPositionMs: 12345,
        globalPositionMs: 12345,
        updatedAt: at(11),
        deviceId: 'this-pc',
      ),
      sessions: [
        SessionSnapshot(
          chapterKey: 'one',
          startedAt: at(12),
          endedAt: at(13),
          startGlobalMs: 1000,
          endGlobalMs: 61000,
          speed: 1.25,
          deviceId: 'this-pc',
        ),
      ],
      bookmarks: [
        BookmarkSnapshot(
          chapterKey: 'one',
          positionMs: 4000,
          title: 'A bookmark',
          note: 'A note.',
          createdAt: at(14),
        ),
      ],
      categories: const ['Next up'],
    ),
  ],
);

/// A library holding only what cannot be left out, so that absent values can be checked to stay
/// absent.
LibrarySnapshot minimalLibrary() => LibrarySnapshot(
  sources: const [
    SourceSnapshot(id: 1, key: 'local', name: 'Local files', lang: 'und'),
  ],
  books: [
    BookSnapshot(
      sourceId: 1,
      key: 'bare',
      details: BookDetailsSnapshot(title: ''),
      createdAt: t0,
      updatedAt: t0,
      mediaFiles: const [
        MediaFileSnapshot(fileKey: 'never-probed'),
        MediaFileSnapshot(fileKey: 'no-markers', embeddedMarkers: []),
      ],
      chapters: [
        ChapterSnapshot(
          key: 'whole',
          title: '',
          sourceIndex: 0,
          createdAt: t0,
          updatedAt: t0,
        ),
      ],
      sessions: [
        SessionSnapshot(
          startedAt: t0,
          endedAt: t0,
          startGlobalMs: 0,
          endGlobalMs: 0,
          speed: 1,
          deviceId: 'this-pc',
        ),
      ],
    ),
  ],
);
