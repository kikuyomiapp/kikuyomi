import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';

/// What reading one audio file found: enough to add it to the library as a book of its own.
typedef _Probe = ({
  int durationMs,
  bool durationIsEstimate,
  int sizeBytes,
  String? bookTitle,
  String? author,
  String? narrator,
  List<TimelineMarker> markers,
  CoverImage? cover,
});

/// The composition root (§2.8): the one place concrete implementations are chosen and wired
/// together. Everything below the app works against interfaces.
final class AppServices {
  AppServices._({
    required this.database,
    required this.coordinator,
    required this.clock,
    required this.locations,
  }) : covers = CoverFiles(locations.covers),
       _importFolder = ImportFolder(mediaRoot: locations.mediaRoot);

  static Future<AppServices> open() async {
    final locations = await StorageLocations.forThisDevice();
    final database = KikuyomiDatabase(
      // §2.7: the database runs in a background isolate, so queries never block a frame.
      NativeDatabase.createInBackground(
        File(_join(locations.appData.path, 'kikuyomi.sqlite')),
      ),
    );
    const clock = SystemClock();
    final audioFocus = await AudioFocus.configure();
    final coordinator = PlaybackCoordinator(
      engine: JustAudioEngine(),
      resolver: LocalMediaResolver(database, mediaRoot: locations.mediaRoot),
      store: DriftPlaybackStore(
        database,
        deviceId: await _deviceId(locations.appData),
        clock: clock,
      ),
      clock: clock,
    );
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
    );
  }

  final KikuyomiDatabase database;
  final PlaybackCoordinator coordinator;
  final Clock clock;
  final StorageLocations locations;

  /// Where the covers of books in the library are kept, and how the names book rows record for them
  /// are found.
  final CoverFiles covers;

  final ImportFolder _importFolder;

  /// The scan of the import folder under way, so that a second request joins it instead of racing
  /// it to add the same books.
  Future<int>? _scan;

  /// The search for covers never looked for, which runs once in the life of the app.
  Future<void>? _coverSearch;

  /// The end of the queue of background work on the library: scans of the import folder, and
  /// looking for one book's cover. They run one at a time, so the two never overlap.
  Future<void> _libraryWork = Future.value();

  /// Adds an audiobook file the user picked in a file dialog, returning the book's id.
  ///
  /// Where the picker hands over only a temporary copy, as on iOS and Android, the copy is moved
  /// into the app's import folder and the book refers to it there. Elsewhere the book refers to the
  /// user's own file.
  Future<int> addPickedBook(String path) async {
    final picked = File(path).absolute;
    // Read before it is moved, so a file that is not a book never enters the import folder.
    final probe = await _probe(picked);
    final storedPath = locations.pickerHandsOverCopies
        ? await _importFolder.adoptCopy(picked)
        : picked.path;
    return _add(probe, storedPath);
  }

  /// Adds the audiobook file at [path] where it is, returning the book's id. For a path given on
  /// the command line, which is always the user's own file.
  Future<int> addBookInPlace(String path) async {
    final file = File(path).absolute;
    return _add(await _probe(file), file.path);
  }

  /// Adds a folder of audio files as one book, referring to the files where they are. Returns the
  /// book's id, and the names of any audio files in the folder that could not be read and were left
  /// out. For a folder picked on desktop, or given on the command line.
  Future<({int bookId, List<String> unreadable})> addFolderBook(
    String path,
  ) async {
    final folder = Directory(path).absolute;
    final book = await readFolderBook(folder);
    if (book == null) {
      throw FormatException('${folder.path} holds no audio this app can read');
    }
    final bookId = await _addFolder(
      book,
      folder: folder,
      key: folder.path,
      pathOf: (name) => _join(folder.path, name),
    );
    return (bookId: bookId, unreadable: book.unreadable);
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
  /// were added.
  ///
  /// On iOS the folder is visible in the Files app, so this is how a book copied there, as a folder
  /// of files or as a single file, reaches the library (§5.1). Elsewhere the folder holds only books
  /// already added through the file picker. A book already known is recognised by its path and not
  /// read again. A folder still being copied when this runs is added with the files that had
  /// arrived by then.
  Future<int> scanImportFolder() =>
      _scan ??= _oneAtATime(_scanImportFolder).whenComplete(() => _scan = null);

  Future<int> _scanImportFolder() async {
    final name = _importFolder.name;
    final folder = Directory('${locations.mediaRoot.path}/$name');
    if (!await folder.exists()) return 0;
    var added = 0;
    await for (final entry in folder.list(followLinks: false)) {
      final entryName = _lastSegment(entry.path);
      final key = '$name/$entryName';
      if (entryName.startsWith('.') || await _isKnown(key)) continue;
      try {
        if (entry is Directory) {
          final book = await readFolderBook(entry);
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
          await _add(await _probe(entry), key);
          added++;
        }
      } on FormatException {
        // Not audio this app can read. It stays in the folder, untouched.
      }
    }
    return added;
  }

  /// Looks for the covers of books in the library whose cover has never been looked for: books
  /// added before covers were kept, and any whose cover could not be written when they were added.
  ///
  /// It runs once in the life of the app, however often it is called, since a book looked at once
  /// is not looked at again. Books take their turn one at a time with scans of the import folder,
  /// so the two never overlap and a scan asked for meanwhile waits for one book rather than for all
  /// of them. A book whose files are missing is skipped quietly, for another start. Any other
  /// failure for one book goes to [onError], and the rest carry on.
  Future<void> lookForMissingCovers({
    required void Function(Object error, StackTrace stack) onError,
  }) => _coverSearch ??= _lookForMissingCovers(onError);

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
      ),
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

  /// Reads an MP3 or an MP4, M4A or M4B file as a book of its own, cover included.
  Future<_Probe> _probe(File file) async {
    final source = await FileByteSource.open(file);
    try {
      if (_extension(file.path) == 'mp3') {
        final info = await readMp3Info(source, withCover: true);
        if (info == null) {
          throw FormatException('${file.path} is not an MP3 file');
        }
        return (
          durationMs: info.durationMs,
          durationIsEstimate: info.durationIsEstimate,
          sizeBytes: source.length,
          // In an MP3 the album names the book; the title more often names a chapter.
          bookTitle: info.album ?? info.title,
          author: info.albumArtist ?? info.artist,
          narrator: info.composer,
          markers: const <TimelineMarker>[],
          cover: _coverImage(info.cover),
        );
      }
      final info = await readMp4Info(source, withCover: true);
      if (info == null) {
        throw FormatException('${file.path} is not an MP4 or M4B file');
      }
      return (
        durationMs: info.durationMs,
        durationIsEstimate: false,
        sizeBytes: source.length,
        bookTitle: info.title ?? info.album,
        author: info.artist ?? info.albumArtist,
        narrator: info.composer,
        markers: [
          for (final chapter in info.chapters?.chapters ?? const <Mp4Chapter>[])
            TimelineMarker(title: chapter.title, startMs: chapter.startMs),
        ],
        cover: _coverImage(info.cover),
      );
    } finally {
      await source.close();
    }
  }

  /// Adds the probed file as a book, stored at [storedPath]: absolute, or relative to the media
  /// root.
  Future<int> _add(_Probe probe, String storedPath) => importLocalBook(
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
