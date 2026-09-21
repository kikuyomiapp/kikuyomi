import 'dart:convert';
import 'dart:io';

import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// [fullLibrary], with a second book in the library and one outside it that is only filed in a
/// category.
LibrarySnapshot twoInLibrary() {
  final full = fullLibrary();
  return LibrarySnapshot(
    sources: full.sources,
    categories: full.categories,
    books: [
      ...full.books,
      BookSnapshot(
        sourceId: catalogSourceId,
        key: '/books/second',
        details: BookDetailsSnapshot(title: 'Second'),
        inLibrary: true,
        createdAt: t0,
        updatedAt: t0,
      ),
      BookSnapshot(
        sourceId: catalogSourceId,
        key: '/books/filed',
        details: BookDetailsSnapshot(title: 'Filed'),
        createdAt: t0,
        updatedAt: t0,
        categories: const ['Next up'],
      ),
    ],
  );
}

void main() {
  final file = encodeBackup(twoInLibrary(), info: info);

  test(
    'says who wrote a backup, when, and how many books its library holds',
    () {
      final summary = readBackupSummary(file);
      expect(summary.info.createdAt, info.createdAt);
      expect(summary.info.appVersion, info.appVersion);
      expect(summary.info.deviceId, info.deviceId);
      expect(summary.formatVersion, backupFormatVersion);
      expect(summary.bookCount, 2);
      expect(summary.isRestorable, isTrue);
    },
  );

  test('agrees with decoding the whole backup', () {
    final summary = readBackupSummary(file);
    final decoded = decodeBackup(file);
    expect(summary.info.createdAt, decoded.info.createdAt);
    expect(summary.formatVersion, decoded.formatVersion);
    expect(
      summary.bookCount,
      decoded.library.books.where((book) => book.inLibrary).length,
    );
  });

  test('counts no books in an empty library', () {
    final empty = encodeBackup(const LibrarySnapshot(), info: info);
    expect(readBackupSummary(empty).bookCount, 0);
  });

  test('refuses a file that is not a complete backup', () {
    for (final bytes in [
      file.sublist(0, file.length ~/ 2),
      [...file]..[file.length ~/ 2] ^= 0xff,
      gzip.encode(utf8.encode('some other gzipped file')),
      gzip.encode(const []),
      utf8.encode('not gzip at all, and long enough to look'),
    ]) {
      expect(
        () => readBackupSummary(bytes),
        throwsA(isA<CorruptBackupException>()),
      );
    }
  });

  test(
    'summarises a backup from a newer format as one this build cannot restore',
    () {
      // Protobuf keeps the last value it reads for a field, so appending min_reader_version (field 2,
      // a varint) makes the backup demand a newer reader than this build.
      final future = gzip.encode([
        ...gzip.decode(file),
        0x10,
        backupFormatVersion + 1,
      ]);
      final summary = readBackupSummary(future);
      expect(summary.minReaderVersion, backupFormatVersion + 1);
      expect(summary.isRestorable, isFalse);
      expect(summary.bookCount, 2);
    },
  );

  test('skips fields added by newer builds', () {
    // Field 99 as a varint holding 1: the tag 99 << 3 is 792, encoded 0x98 0x06.
    final newer = gzip.encode([...gzip.decode(file), 0x98, 0x06, 0x01]);
    final summary = readBackupSummary(newer);
    expect(summary.bookCount, 2);
    expect(summary.isRestorable, isTrue);
  });
}
