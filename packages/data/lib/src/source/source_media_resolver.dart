/// §6.3's resolver for a book that streams from a source.
///
/// "Media resolution must be lazy: stream URLs are ephemeral, header-dependent, and often come in
/// quality variants, so they are fetched immediately before use rather than stored" (§1.2). This is
/// that, for a `ContentSource`: it turns the physical file the player asks for back into the chapter
/// it belongs to, asks the source where that chapter's audio is, and hands the engine a URL and the
/// headers it needs.
///
/// **What it stores and what it does not.** The *layout* the first resolution returns is written
/// down — which files a chapter is made of, and which stretch of each — because §4.3 wants the
/// Timeline, offline playback and progress arithmetic to work without calling the extension. The
/// URLs are not: "URLs are deliberately not stored here; they're ephemeral." They live in this
/// resolver's memory for as long as the source says they are good for, and no longer.
library;

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart' as api;

import '../database/database.dart';
import '../local/local_import.dart' show localSourceId;
import '../local/local_media_resolver.dart';
import 'source_books.dart';

/// Opens the source with [sourceId], starting its runtime if it is not running yet.
///
/// A function rather than a registry, so this package neither runs an extension nor knows what one
/// is: `source_runtime` and the composition root do.
typedef OpenSource = Future<api.ContentSource> Function(int sourceId);

/// Resolves a streamed book's files through its source.
///
/// A file already on the device — a local book, or a download — is answered by [onDevice] without
/// asking the source anything, so one resolver serves a library holding both kinds of book. A
/// download that has gone missing falls through to the source, because the source still has it and
/// failing playback over a file the listener may have cleared themselves would be unhelpful; a local
/// book's missing file does not, because nothing can bring it back.
final class SourceMediaResolver implements MediaResolver {
  SourceMediaResolver(
    this._db, {
    required this.openSource,
    required this.onDevice,
    required this.clock,
    this.network = api.NetworkType.unknown,
  });

  final KikuyomiDatabase _db;

  /// How a source is reached.
  final OpenSource openSource;

  /// The resolver for files already on this device, which is `LocalMediaResolver`.
  final MediaResolver onDevice;

  final Clock clock;

  /// What the source is told about the connection, so it can offer a smaller variant on cellular.
  ///
  /// Fixed at `unknown` for now, which the contract provides for. Telling wifi from cellular takes a
  /// connectivity plugin behind an adapter, and until there is one, saying "unknown" is honest where
  /// guessing "wifi" would quietly cost someone their data.
  final api.NetworkType network;

  /// What a source last said, by file id. Kept only in memory: §4.3 treats these URLs as ephemeral,
  /// and a token written to disk outlives its usefulness and is a secret nobody asked to keep.
  final _resolved = <int, ResolvedMedia>{};

  /// Forgets everything resolved, as closing a book or disabling a source should.
  void clearCache() => _resolved.clear();

  @override
  Future<ResolvedMedia> resolve(int fileId, {bool refresh = false}) async {
    final file = await (_db.select(
      _db.mediaFiles,
    )..where((f) => f.id.equals(fileId))).getSingleOrNull();
    if (file == null) {
      throw MediaUnavailableException('no media file with id $fileId');
    }

    final book = await (_db.select(
      _db.books,
    )..where((b) => b.id.equals(file.bookId))).getSingleOrNull();
    if (book == null) {
      throw MediaUnavailableException(
        'file "${file.fileKey}" belongs to no book',
      );
    }

    final isLocal = book.sourceId == localSourceId;
    if (isLocal || file.localPath != null) {
      try {
        return await onDevice.resolve(fileId, refresh: refresh);
      } on MediaUnavailableException {
        if (isLocal) rethrow;
      }
    }

    if (!refresh) {
      final cached = _resolved[fileId];
      if (cached != null && !_hasExpired(cached)) return cached;
    }
    _resolved.remove(fileId);
    final chapter = await _chapterOf(fileId);
    if (chapter == null) {
      throw MediaUnavailableException(
        'file "${file.fileKey}" belongs to no chapter of "${book.title}"',
      );
    }

    final source = await openSource(book.sourceId);
    final resolution = await source.resolveMedia(
      api.ChapterRef(bookKey: book.key, chapterKey: chapter.key),
      api.ResolveContext(purpose: api.ResolvePurpose.stream, network: network),
    );

    final media = await _db.transaction(
      () => _applyResolution(
        book: book,
        chapterId: chapter.id,
        fileId: fileId,
        resolution: resolution,
      ),
    );
    _resolved[fileId] = media;
    return media;
  }

  bool _hasExpired(ResolvedMedia media) {
    final expires = media.expiresAt;
    return expires != null && !clock.now().isBefore(expires);
  }

  /// The chapter the player is playing this file for: the first, in the book's order, whose layout
  /// names it. A file shared by several chapters is resolved through whichever comes first, which is
  /// what a source that packs a book into one file expects to be asked about.
  Future<ChapterRow?> _chapterOf(int fileId) async {
    final rows =
        await (_db.select(_db.chapters).join([
                innerJoin(
                  _db.chapterSegments,
                  _db.chapterSegments.chapterId.equalsExp(_db.chapters.id),
                ),
              ])
              ..where(
                _db.chapterSegments.mediaFileId.equals(fileId) &
                    _db.chapters.removedFromSource.equals(false),
              )
              ..orderBy([
                OrderingTerm.asc(_db.chapters.sourceIndex),
                OrderingTerm.asc(_db.chapters.id),
              ])
              ..limit(1))
            .get();
    return rows.isEmpty ? null : rows.first.readTable(_db.chapters);
  }

  /// Writes the layout [resolution] describes and returns where the file the player asked for is.
  ///
  /// **The estimate is consumed, not replaced, wherever it can be.** A chapter that has never been
  /// resolved is stored as one estimated file (`saveSourceBook`), and the player is already holding
  /// that file's id inside the Timeline it is playing. When the resolution is one file the book does
  /// not already know — which is every source that gives a file per chapter, LibriVox included — the
  /// estimate's row takes the real file's key in place, so the id the player holds stays the id of
  /// the file it is playing, and §4.5 refines the estimated duration as soon as the engine reports
  /// the real one.
  ///
  /// When it cannot — a chapter that turns out to span several files, or to share a file another
  /// chapter already has — the chapter's layout is rewritten and the estimate dropped. The player
  /// carries on with the URL this call returns, and the new layout is what the book is opened with
  /// next time. Rewriting the Timeline of a book already playing is a larger change than a first
  /// stream is worth, and no source seen so far needs it.
  Future<ResolvedMedia> _applyResolution({
    required BookRow book,
    required int chapterId,
    required int fileId,
    required api.MediaResolution resolution,
  }) async {
    final rows = {
      for (final row in await (_db.select(
        _db.mediaFiles,
      )..where((f) => f.bookId.equals(book.id))).get())
        row.fileKey: row,
    };
    final asked = rows.values.where((row) => row.id == fileId).firstOrNull;
    final first = resolution.segments.first;

    if (asked != null &&
        isEstimatedFileKey(asked.fileKey) &&
        !rows.containsKey(first.fileKey)) {
      rows.remove(asked.fileKey);
      rows[first.fileKey] = asked.copyWith(fileKey: first.fileKey);
      await (_db.update(_db.mediaFiles)..where((f) => f.id.equals(fileId)))
          .write(MediaFilesCompanion(fileKey: Value(first.fileKey)));
    }

    final idByKey = <String, int>{};
    for (final segment in resolution.segments) {
      final known = rows[segment.fileKey];
      if (known == null) {
        final id = await _db
            .into(_db.mediaFiles)
            .insert(
              MediaFilesCompanion(
                bookId: Value(book.id),
                fileKey: Value(segment.fileKey),
                format: Value(
                  segment.format == api.MediaFormat.unknown
                      ? null
                      : segment.format.name,
                ),
                durationMs: Value(segment.durationMs),
                // A source's figure is a claim, not a probe. §4.5 keeps estimated durations apart
                // from known ones, and only the engine playing the file settles it.
                durationIsEstimate: const Value(true),
                sizeBytes: Value(segment.sizeBytes),
              ),
            );
        idByKey[segment.fileKey] = id;
        rows[segment.fileKey] = (await (_db.select(
          _db.mediaFiles,
        )..where((f) => f.id.equals(id))).getSingle());
      } else {
        idByKey[segment.fileKey] = known.id;
        await (_db.update(
          _db.mediaFiles,
        )..where((f) => f.id.equals(known.id))).write(
          MediaFilesCompanion(
            format: segment.format == api.MediaFormat.unknown
                ? const Value.absent()
                : Value(segment.format.name),
            sizeBytes: segment.sizeBytes == null
                ? const Value.absent()
                : Value(segment.sizeBytes),
            // A duration already learned from the file itself is better evidence than a source's
            // word, so it stands.
            durationMs: segment.durationMs == null || !known.durationIsEstimate
                ? const Value.absent()
                : Value(segment.durationMs),
          ),
        );
      }
    }

    await (_db.delete(
      _db.chapterSegments,
    )..where((s) => s.chapterId.equals(chapterId))).go();
    for (final (ordinal, segment) in resolution.segments.indexed) {
      await _db
          .into(_db.chapterSegments)
          .insert(
            ChapterSegmentsCompanion(
              chapterId: Value(chapterId),
              ordinal: Value(ordinal),
              mediaFileId: Value(idByKey[segment.fileKey]!),
              startMs: Value(segment.range?.startMs ?? 0),
              endMs: Value(segment.range?.endMs),
            ),
          );
    }
    await _dropUnusedEstimates(book.id);

    // The file the player asked for, if it still exists; otherwise the first of the new layout,
    // which is where the chapter starts.
    final target = idByKey.values.contains(fileId)
        ? fileId
        : idByKey[first.fileKey]!;
    final segment = resolution.segments.firstWhere(
      (segment) => idByKey[segment.fileKey] == target,
      orElse: () => first,
    );
    if (segment.request.method != api.HttpMethod.get) {
      throw MediaUnavailableException(
        'the player can only fetch audio with GET, and "${book.title}" asks for '
        '${segment.request.method.wireName}',
      );
    }
    return ResolvedMedia(
      uri: segment.request.url,
      headers: segment.request.headers,
      expiresAt: resolution.expiresAt,
    );
  }

  /// Removes the estimated files of [bookId] that no chapter's layout names any more.
  ///
  /// Only estimates: a real file with no layout may still be downloaded, and dropping its row would
  /// lose the download with it.
  Future<void> _dropUnusedEstimates(int bookId) async {
    final used = {
      for (final row in await (_db.select(_db.chapterSegments).join([
        innerJoin(
          _db.chapters,
          _db.chapters.id.equalsExp(_db.chapterSegments.chapterId),
        ),
      ])..where(_db.chapters.bookId.equals(bookId))).get())
        row.readTable(_db.chapterSegments).mediaFileId,
    };
    final estimates = await (_db.select(
      _db.mediaFiles,
    )..where((f) => f.bookId.equals(bookId))).get();
    for (final file in estimates) {
      if (!isEstimatedFileKey(file.fileKey) || used.contains(file.id)) continue;
      await (_db.delete(
        _db.mediaFiles,
      )..where((f) => f.id.equals(file.id))).go();
    }
  }
}
