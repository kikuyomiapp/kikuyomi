import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
// Named apart, because AppServices has methods of the same names that also tell the player.
import 'package:kikuyomi_data/kikuyomi_data.dart'
    as data
    show markBookFinished, markBookNotFinished;
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';

import 'app_version.dart';
import 'book_files.dart';

/// The composition root (§2.8): the one place concrete implementations are chosen and wired
/// together. Everything below the app works against interfaces.
final class AppServices {
  AppServices._({
    required this.database,
    required this.coordinator,
    required this.clock,
    required this.locations,
    required this.settings,
    required this.backups,
    required this.backupScheduler,
    required this.playable,
  }) : covers = CoverFiles(locations.covers),
       _importFolder = ImportFolder(mediaRoot: locations.mediaRoot);

  static Future<AppServices> open() async {
    final locations = await StorageLocations.forThisDevice();
    final settings = await SharedPreferencesSettingsStore.open();
    final database = KikuyomiDatabase(
      // §2.7: the database runs in a background isolate, so queries never block a frame.
      NativeDatabase.createInBackground(
        File(_join(locations.appData.path, 'kikuyomi.sqlite')),
      ),
    );
    const clock = SystemClock();
    await _backfillListened(database, settings);
    final deviceId = await _deviceId(locations.appData);
    final audioFocus = await AudioFocus.configure();
    final coordinator = PlaybackCoordinator(
      engine: JustAudioEngine(),
      resolver: LocalMediaResolver(database, mediaRoot: locations.mediaRoot),
      store: DriftPlaybackStore(database, deviceId: deviceId, clock: clock),
      clock: clock,
    );
    // §5.1: automatic backups to the folder the user chose, which outlives an Android uninstall and
    // an iOS re-sign.
    final backupStore = DriftBackupStore(database);
    final backups = BackupService(
      library: backupStore,
      restorer: backupStore,
      folders: DeviceFolders.forThisDevice(),
      settings: settings,
      clock: clock,
      appVersion: appVersion,
      deviceId: deviceId,
    );
    // Starting it only subscribes to the database's change notifications. Nothing is read or written
    // until changes have settled, so it costs the first frame nothing.
    final backupScheduler = BackupScheduler(
      backUp: backups.backUp,
      changes: backedUpChanges(database),
      settings: settings,
      clock: clock,
    )..start();
    // Calls, navigation prompts and unplugged headphones go to the coordinator, which decides what
    // each means for the book (§6.5). The subscription lasts as long as the app.
    audioFocus.events.listen(
      (event) => unawaited(coordinator.onSystemAudio(event)),
    );
    // The lock screen, the notification and headset buttons, or on Windows the media keys and the
    // volume flyout (§6.5). Its subscriptions keep it alive for as long as the app runs.
    MediaSessionSync(
      coordinator: coordinator,
      bridge: await SystemMediaControls.start(skipInterval: _skipInterval),
      describe: (bookId) => _describeBook(database, bookId),
      clock: clock,
      skipInterval: _skipInterval,
    ).start();
    return AppServices._(
      database: database,
      coordinator: coordinator,
      clock: clock,
      locations: locations,
      settings: settings,
      backups: backups,
      backupScheduler: backupScheduler,
      playable: EngineFormats.forThisDevice(),
    );
  }

  final KikuyomiDatabase database;
  final PlaybackCoordinator coordinator;
  final Clock clock;
  final StorageLocations locations;

  /// App preferences (§4.3).
  final SettingsStore settings;

  /// The backup folder, writing backups to it, and restoring from them.
  final BackupService backups;

  /// When automatic backups run.
  final BackupScheduler backupScheduler;

  /// The audio formats the player can play on this device (§7.3). A book in any other is refused
  /// as it is added, rather than added to fail when it is opened.
  final PlayableFormats playable;

  /// Where the covers of books in the library are kept, and how the names book rows record for them
  /// are found.
  final CoverFiles covers;

  final ImportFolder _importFolder;

  /// The scan of the import folder under way, so that a second request joins it instead of racing
  /// it to add the same books.
  Future<ImportScan>? _scan;

  /// The search for covers never looked for, while one is under way.
  Future<void>? _coverSearch;

  /// The end of the queue of background work on the library: scans of the import folder, and
  /// looking for one book's cover. They run one at a time, so the two never overlap.
  Future<void> _libraryWork = Future.value();

  /// Adds an audiobook file the user picked in a file dialog, returning the book's id.
  ///
  /// Where the picker hands over only a temporary copy, as on iOS and Android, the copy is moved
  /// into the app's import folder and the book refers to it there. Elsewhere the book refers to the
  /// user's own file.
  ///
  /// A file this device cannot play is refused with an [UnplayableFormatException] naming its
  /// format, as [probeBookFile] describes.
  Future<int> addPickedBook(String path) async {
    final picked = File(path).absolute;
    // Read before it is moved, so a file that is not a book, or one that will not play here, never
    // enters the import folder.
    final probe = await probeBookFile(picked, playable);
    final storedPath = locations.pickerHandsOverCopies
        ? await _importFolder.adoptCopy(picked)
        : picked.path;
    return _add(probe, storedPath);
  }

  /// Adds the audiobook file at [path] where it is, returning the book's id. For a path given on
  /// the command line, which is always the user's own file.
  Future<int> addBookInPlace(String path) async {
    final file = File(path).absolute;
    return _add(await probeBookFile(file, playable), file.path);
  }

  /// Adds a folder of audio files as one book, referring to the files where they are. Returns the
  /// book's id, and the audio files in the folder that were left out: those that could not be read,
  /// and those in a format this device cannot play. For a folder picked on desktop, or given on the
  /// command line.
  ///
  /// A folder with no audio this device can play is refused, with an [UnplayableFormatException]
  /// naming the formats when it holds audio in others, as [readPlayableFolder] describes.
  Future<({int bookId, LeftOut leftOut})> addFolderBook(String path) async {
    final folder = Directory(path).absolute;
    final book = await readPlayableFolder(folder, playable);
    if (book == null) {
      throw FormatException('${folder.path} holds no audio this app can read');
    }
    final bookId = await _addFolder(
      book,
      folder: folder,
      key: folder.path,
      pathOf: (name) => _join(folder.path, name),
    );
    return (bookId: bookId, leftOut: LeftOut.of(book));
  }

  /// The title of book [bookId], as the library shows it: for telling the listener which book was
  /// added, when that was read from the book's own tags rather than chosen by name.
  Future<String> bookTitle(int bookId) async {
    final book = await (database.select(
      database.books,
    )..where((b) => b.id.equals(bookId))).getSingle();
    return book.title;
  }

  /// Adds the books copied into the import folder since it was last looked in, and returns how many
  /// were added, and which files and folders were not because this device cannot play them.
  ///
  /// On iOS the folder is visible in the Files app, so this is how a book copied there, as a folder
  /// of files or as a single file, reaches the library (§5.1). Elsewhere the folder holds only books
  /// already added through the file picker. A book already known is recognised by its path and not
  /// read again. A folder still being copied when this runs is added with the files that had
  /// arrived by then. What cannot be added stays in the folder, untouched, and is looked at again
  /// the next time.
  Future<ImportScan> scanImportFolder() =>
      _scan ??= _oneAtATime(_scanImportFolder).whenComplete(() => _scan = null);

  Future<ImportScan> _scanImportFolder() async {
    final name = _importFolder.name;
    final folder = Directory('${locations.mediaRoot.path}/$name');
    final unplayable = <({String name, UnplayableFormatException reason})>[];
    if (!await folder.exists()) return (added: 0, unplayable: unplayable);
    var added = 0;
    await for (final entry in folder.list(followLinks: false)) {
      final entryName = _lastSegment(entry.path);
      final key = '$name/$entryName';
      if (entryName.startsWith('.') || await _isKnown(key)) continue;
      try {
        if (entry is Directory) {
          final book = await readPlayableFolder(entry, playable);
          if (book == null) continue;
          await _addFolder(
            book,
            folder: entry,
            key: key,
            pathOf: (file) => '$key/$file',
          );
          added++;
        } else if (entry is File &&
            audioExtensions.contains(_extension(entryName))) {
          await _add(await probeBookFile(entry, playable), key);
          added++;
        }
      } on FormatException {
        // Not audio this app can read.
      } on UnplayableFormatException catch (reason) {
        unplayable.add((name: entryName, reason: reason));
      }
    }
    return (added: added, unplayable: unplayable);
  }

  /// Looks for the covers of books in the library whose cover has never been looked for: books
  /// added before covers were kept, and any whose cover could not be written when they were added.
  ///
  /// A book looked at once is not looked at again, so after the search at start another finds only
  /// books that arrived since without a cover, as a restore brings them. A call while a search is
  /// under way joins it. Books take their turn one at a time with scans of the import folder, so the
  /// two never overlap and a scan asked for meanwhile waits for one book rather than for all of
  /// them. A book whose files are missing is skipped quietly, for another start. Any other failure
  /// for one book goes to [onError], and the rest carry on.
  Future<void> lookForMissingCovers({
    required void Function(Object error, StackTrace stack) onError,
  }) =>
      _coverSearch ??= _lookForMissingCovers(onError)
          .whenComplete(() => _coverSearch = null);

  /// Whether the library holds no books at all: what a fresh install looks like.
  Future<bool> libraryIsEmpty() async =>
      await (database.select(database.books)
            ..where((b) => b.inLibrary.equals(true))
            ..limit(1))
          .getSingleOrNull() ==
      null;

  /// Does for a library just restored what start does for the library there was: adds the books
  /// copied into the import folder, and looks for the covers of books without one, since a backup
  /// carries no cover images. Failures go to [onError].
  Future<void> settleRestoredLibrary({
    required void Function(Object error, StackTrace stack) onError,
  }) async {
    try {
      await scanImportFolder();
    } catch (error, stack) {
      onError(error, stack);
    }
    await lookForMissingCovers(onError: onError);
  }

  Future<void> _lookForMissingCovers(
    void Function(Object error, StackTrace stack) onError,
  ) async {
    for (final book in await localBooksAwaitingCover(database)) {
      try {
        await _oneAtATime(
          () => lookForLocalCover(
            database,
            book,
            mediaRoot: locations.mediaRoot,
            read: _readCover,
            covers: covers,
            clock: clock,
          ),
        );
      } catch (error, stack) {
        onError(error, stack);
      }
    }
  }

  /// Opens a book in the player, resuming where it was left with smart rewind applied.
  Future<void> openBook(int bookId) async {
    final stored = await loadStoredPlayback(database, bookId);
    final lastPlayedAt = stored.lastPlayedAt;
    await coordinator.open(
      PlaybackRequest(
        bookId: bookId,
        timeline: stored.timeline,
        resumeFrom: stored.resumeFrom,
        pausedFor: lastPlayedAt == null
            ? Duration.zero
            : clock.now().difference(lastPlayedAt),
        speed: stored.speed ?? 1.0,
        finished: stored.finished,
      ),
    );
  }

  /// Marks chapters [chapterIds] of book [bookId] listened, or not, by hand (§4.5), and returns
  /// those it changed.
  ///
  /// The player is told as well, in case the book is open there, so that what it says about the
  /// book being finished stays the same as what the book's details and Continue Listening say.
  Future<Set<int>> markChaptersListened(
    int bookId,
    Iterable<int> chapterIds, {
    required bool listened,
  }) async {
    final changed = await setChaptersListened(
      database,
      bookId: bookId,
      chapterIds: chapterIds,
      listened: listened,
      clock: clock,
    );
    await coordinator.onListenedChanged(
      bookId: bookId,
      chapterIds: changed,
      listened: listened,
    );
    return changed;
  }

  /// Marks book [bookId] finished by hand, every chapter listened, and returns the chapters that
  /// were not, which are the ones to mark not listened again to undo it. The player is told, as
  /// for [markChaptersListened].
  Future<Set<int>> markBookFinished(int bookId) async {
    final changed = await data.markBookFinished(database, bookId, clock: clock);
    await coordinator.onListenedChanged(
      bookId: bookId,
      chapterIds: changed,
      listened: true,
    );
    return changed;
  }

  /// Marks book [bookId] not finished by hand, its last chapter not listened. The player is told,
  /// as for [markChaptersListened].
  Future<void> markBookNotFinished(int bookId) async {
    final changed = await data.markBookNotFinished(
      database,
      bookId,
      clock: clock,
    );
    await coordinator.onListenedChanged(
      bookId: bookId,
      chapterIds: changed,
      listened: false,
    );
  }

  /// Runs [work] once the background work queued before it has finished, failed or not.
  Future<T> _oneAtATime<T>(Future<T> Function() work) {
    final result = _libraryWork.then((_) => work());
    _libraryWork = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<bool> _isKnown(String key) async =>
      await (database.select(
            database.books,
          )..where((b) => b.sourceId.equals(localSourceId) & b.key.equals(key)))
          .getSingleOrNull() !=
      null;

  /// Adds the probed file as a book, stored at [storedPath]: absolute, or relative to the media
  /// root.
  Future<int> _add(ProbedBook probe, String storedPath) => importLocalBook(
    database,
    LocalBookImport(
      file: LocalBookFile(
        path: storedPath,
        durationMs: probe.durationMs,
        durationIsEstimate: probe.durationIsEstimate,
        sizeBytes: probe.sizeBytes,
        format: _extension(storedPath),
        markers: probe.markers,
      ),
      title: probe.bookTitle ?? _stem(storedPath),
      authors: [?probe.author],
      narrators: [?probe.narrator],
      cover: probe.cover,
    ),
    clock: clock,
    covers: covers,
  );

  /// Adds a folder read as a book under [key], with each file stored at the path [pathOf] gives
  /// its name. [folder] is where the folder is, to read its cover from.
  Future<int> _addFolder(
    FolderBook book, {
    required Directory folder,
    required String key,
    required String Function(String fileName) pathOf,
  }) async {
    CoverImage? cover;
    var coverRead = true;
    try {
      final image = book.coverFileName;
      cover = _coverImage(
        await readLocalCover(
          File(_join(folder.path, book.tracks.first.fileName)),
          image: image == null ? null : File(_join(folder.path, image)),
        ),
      );
    } on FileSystemException {
      // The first track went missing since the folder was read. Adding the book does not wait on
      // its cover, which is left to be looked for later.
      coverRead = false;
    }
    return importLocalFolderBook(
      database,
      LocalFolderImport(
        key: key,
        title: book.title,
        authors: book.authors,
        narrators: book.narrators,
        cover: cover,
        tracks: [
          for (final track in book.tracks)
            LocalTrackImport(
              file: LocalBookFile(
                path: pathOf(track.fileName),
                durationMs: track.durationMs,
                durationIsEstimate: track.durationIsEstimate,
                sizeBytes: track.sizeBytes,
                format: track.format,
              ),
              title: track.title,
            ),
        ],
      ),
      clock: clock,
      covers: coverRead ? covers : null,
    );
  }
}

/// §4.5: records as listened the chapters listened to before listened state was recorded, from the
/// positions saved in them, once for this installation.
///
/// It runs as the app opens, before any screen reads listened state and before the player can record
/// any, so nothing is ever shown unlistened that was shown listened before, and no chapter the
/// listener has since marked by hand is touched. A failure is reported the way Flutter reports
/// errors and does not stop the app: the backfill is not recorded as done, so it is tried again at
/// the next start.
Future<void> _backfillListened(
  KikuyomiDatabase database,
  SettingsStore settings,
) async {
  try {
    await backfillListenedChaptersOnce(database, settings);
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'kikuyomi',
        context: ErrorDescription(
          'while recording chapters listened before listened state was recorded',
        ),
      ),
    );
  }
}

String _join(String directory, String name) =>
    '$directory${Platform.pathSeparator}$name';

/// How far the system controls' skip buttons move: the same as the player screen's.
const _skipInterval = Duration(seconds: 30);

/// Reads the cover of a book already in the library: for a book in a folder, the image there named
/// as its cover, or failing that the picture in its first file; for a book in one file, the picture
/// in it.
Future<CoverImage?> _readCover(File audio, Directory? folder) async {
  final image = folder == null ? null : await findFolderCoverImage(folder);
  return _coverImage(await readLocalCover(audio, image: image));
}

CoverImage? _coverImage(EmbeddedPicture? picture) => picture == null
    ? null
    : CoverImage(mimeType: picture.mimeType, bytes: picture.bytes);

/// A book's title and first author, as the system's media controls name it.
Future<BookDescription> _describeBook(KikuyomiDatabase db, int bookId) async {
  final book = await (db.select(
    db.books,
  )..where((b) => b.id.equals(bookId))).getSingle();
  final credit =
      await (db.select(db.bookPeople)
            ..where(
              (c) =>
                  c.bookId.equals(bookId) &
                  c.role.equalsValue(ContributorRole.author),
            )
            ..orderBy([(c) => OrderingTerm.asc(c.ordinal)])
            ..limit(1))
          .getSingleOrNull();
  final author = credit == null
      ? null
      : await (db.select(
          db.people,
        )..where((p) => p.id.equals(credit.personId))).getSingle();
  return BookDescription(title: book.title, author: author?.name);
}

String _lastSegment(String path) {
  final segments = path.split(RegExp(r'[\\/]'))
    ..removeWhere((segment) => segment.isEmpty);
  return segments.isEmpty ? path : segments.last;
}

String _stem(String path) {
  final name = _lastSegment(path);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String? _extension(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? null : path.substring(dot + 1).toLowerCase();
}

/// A random id for this installation, created once and kept beside the database. §4.3 stores it
/// with progress and listening sessions, so that sync can later tell devices apart.
Future<String> _deviceId(Directory directory) async {
  final file = File(_join(directory.path, 'device_id'));
  if (await file.exists()) return (await file.readAsString()).trim();
  final random = Random.secure();
  final id = [
    for (var i = 0; i < 16; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
  await file.writeAsString(id);
  return id;
}
