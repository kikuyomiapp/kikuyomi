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
    this.onTiming,
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

  /// Where the time each resolution spends is reported, or null to measure nothing.
  final TimingSink? onTiming;

  /// What a source last said, by file id. Kept only in memory: §4.3 treats these URLs as ephemeral,
  /// and a token written to disk outlives its usefulness and is a secret nobody asked to keep.
  final _resolved = <int, ResolvedMedia>{};

  /// The resolution of each file being worked on, so that two callers asking for one file at the
  /// same time cost the source one call rather than two.
  ///
  /// A book is resolved from two directions at once: the engine asks for the file it is about to
  /// play, and the background pass walks the rest. Without this they would race on the same file
  /// and each write its own copy of the layout.
  final _inFlight = <int, Future<ResolvedMedia>>{};

  /// Forgets everything resolved, as closing a book or disabling a source should.
  void clearCache() => _resolved.clear();

  @override
  Future<ResolvedMedia?> resolveIfOnHand(int fileId) async {
    final rows = await _rowsFor(fileId);
    if (rows == null) return null;
    final (:file, :book) = rows;
    final isLocal = book.sourceId == localSourceId;
    if (isLocal || file.localPath != null) {
      try {
        return await onDevice.resolve(fileId);
      } on MediaUnavailableException {
        // A local book's file is gone, or a download has been cleared. Either way there is nothing
        // in hand; the source may still have it, which resolving it properly will find out.
        if (isLocal) return null;
      }
    }
    final cached = _resolved[fileId];
    return cached != null && !_hasExpired(cached) ? cached : null;
  }

  @override
  Future<ResolvedMedia> resolve(int fileId, {bool refresh = false}) {
    final running = refresh ? null : _inFlight[fileId];
    if (running != null) return running;
    final work = _resolveNow(fileId, refresh: refresh);
    _inFlight[fileId] = work;
    return work.whenComplete(() {
      if (identical(_inFlight[fileId], work)) _inFlight.remove(fileId);
    });
  }

  Future<ResolvedMedia> _resolveNow(int fileId, {required bool refresh}) async {
    final watch = onTiming == null ? null : (Stopwatch()..start());
    final rows = await _rowsFor(fileId);
    if (rows == null) {
      throw MediaUnavailableException('no media file with id $fileId');
    }
    final (:file, :book) = rows;

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
    final askedAt = watch?.elapsed;
    final resolution = await source.resolveMedia(
      api.ChapterRef(bookKey: book.key, chapterKey: chapter.key),
      api.ResolveContext(purpose: api.ResolvePurpose.stream, network: network),
    );
    final answeredAt = watch?.elapsed;

    final media = await _apply(
      book: book,
      chapterId: chapter.id,
      fileId: fileId,
      resolution: resolution,
    );
    _resolved[fileId] = media;
    if (watch != null && askedAt != null && answeredAt != null) {
      onTiming!('resolve.source', answeredAt - askedAt);
      onTiming!('resolve.store', watch.elapsed - answeredAt);
      onTiming!('resolve', watch.elapsed);
    }
    return media;
  }

  /// Writes what [resolution] says, unless the book already says it.
  ///
  /// A chapter whose layout has been stored once is resolved again at every open, because the URLs
  /// are not stored and only the source has them. What comes back is then the layout that is
  /// already there, and writing it again would cost a transaction and a round of change
  /// notifications for nothing. Only a layout that differs is written.
  ///
  /// A file's format and size are left as they were on that path. They were written when the layout
  /// was, and neither changes for a file that is still the same file.
  Future<ResolvedMedia> _apply({
    required BookRow book,
    required int chapterId,
    required int fileId,
    required api.MediaResolution resolution,
  }) async {
    final stored = await _storedLayout(chapterId);
    if (_sameLayout(stored, resolution)) {
      return _mediaFor(
        resolution: resolution,
        book: book,
        idByKey: {for (final row in stored) row.fileKey: row.fileId},
        fileId: fileId,
      );
    }
    return _db.transaction(
      () => _applyResolution(
        book: book,
        chapterId: chapterId,
        fileId: fileId,
        resolution: resolution,
      ),
    );
  }

  /// The file row and the book row behind [fileId], or null when either is missing.
  Future<({MediaFileRow file, BookRow book})?> _rowsFor(int fileId) async {
    final file = await (_db.select(
      _db.mediaFiles,
    )..where((f) => f.id.equals(fileId))).getSingleOrNull();
    if (file == null) return null;
    final book = await (_db.select(
      _db.books,
    )..where((b) => b.id.equals(file.bookId))).getSingleOrNull();
    return book == null ? null : (file: file, book: book);
  }

  /// The layout stored for [chapterId], in order.
  Future<List<({int fileId, String fileKey, int startMs, int? endMs})>>
  _storedLayout(int chapterId) async {
    final rows =
        await (_db.select(_db.chapterSegments).join([
                innerJoin(
                  _db.mediaFiles,
                  _db.mediaFiles.id.equalsExp(_db.chapterSegments.mediaFileId),
                ),
              ])
              ..where(_db.chapterSegments.chapterId.equals(chapterId))
              ..orderBy([OrderingTerm.asc(_db.chapterSegments.ordinal)]))
            .get();
    return [
      for (final row in rows)
        (
          fileId: row.readTable(_db.mediaFiles).id,
          fileKey: row.readTable(_db.mediaFiles).fileKey,
          startMs: row.readTable(_db.chapterSegments).startMs,
          endMs: row.readTable(_db.chapterSegments).endMs,
        ),
    ];
  }

  static bool _sameLayout(
    List<({int fileId, String fileKey, int startMs, int? endMs})> stored,
    api.MediaResolution resolution,
  ) {
    if (stored.isEmpty || stored.length != resolution.segments.length) {
      return false;
    }
    for (final (index, segment) in resolution.segments.indexed) {
      final row = stored[index];
      if (row.fileKey != segment.fileKey ||
          row.startMs != (segment.range?.startMs ?? 0) ||
          row.endMs != segment.range?.endMs) {
        return false;
      }
    }
    return true;
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

    return _mediaFor(
      resolution: resolution,
      book: book,
      idByKey: idByKey,
      fileId: fileId,
    );
  }

  /// Where the file the player asked for is, out of what [resolution] gave.
  ///
  /// The file the player asked for, if the layout still holds it; otherwise the first segment,
  /// which is where the chapter starts.
  static ResolvedMedia _mediaFor({
    required api.MediaResolution resolution,
    required BookRow book,
    required Map<String, int> idByKey,
    required int fileId,
  }) {
    final first = resolution.segments.first;
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
