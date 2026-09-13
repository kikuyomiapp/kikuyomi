import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';

/// What reading a file's MP4 structure found.
typedef _Probe = ({Mp4Info info, int sizeBytes});

/// The composition root (§2.8): the one place concrete implementations are chosen and wired
/// together. Everything below the app works against interfaces.
final class AppServices {
  AppServices._({
    required this.database,
    required this.coordinator,
    required this.clock,
    required this.locations,
  }) : _importFolder = ImportFolder(mediaRoot: locations.mediaRoot);

  static Future<AppServices> open() async {
    final locations = await StorageLocations.forThisDevice();
    final database = KikuyomiDatabase(
      // §2.7: the database runs in a background isolate, so queries never block a frame.
      NativeDatabase.createInBackground(
        File(_join(locations.appData.path, 'kikuyomi.sqlite')),
      ),
    );
    const clock = SystemClock();
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
  final ImportFolder _importFolder;

  /// Adds an MP4 or M4B the user picked in a file dialog, returning the book's id.
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

  /// Adds the MP4 or M4B at [path] where it is, returning the book's id. For a path given on the
  /// command line, which is always the user's own file.
  Future<int> addBookInPlace(String path) async {
    final file = File(path).absolute;
    return _add(await _probe(file), file.path);
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

  Future<_Probe> _probe(File file) async {
    final source = await FileByteSource.open(file);
    try {
      final info = await readMp4Info(source);
      if (info == null) {
        throw FormatException('${file.path} is not an MP4 or M4B file');
      }
      return (info: info, sizeBytes: source.length);
    } finally {
      await source.close();
    }
  }

  /// Adds the probed book, stored at [storedPath]: absolute, or relative to the media root.
  Future<int> _add(_Probe probe, String storedPath) {
    final info = probe.info;
    return importLocalBook(
      database,
      LocalBookImport(
        file: LocalBookFile(
          path: storedPath,
          durationMs: info.durationMs,
          sizeBytes: probe.sizeBytes,
          format: _extension(storedPath),
          markers: [
            for (final chapter
                in info.chapters?.chapters ?? const <Mp4Chapter>[])
              TimelineMarker(title: chapter.title, startMs: chapter.startMs),
          ],
        ),
        title: info.title ?? info.album ?? _stem(storedPath),
        authors: [?info.artist],
        narrators: [?info.composer],
      ),
      clock: clock,
    );
  }
}

String _join(String directory, String name) =>
    '$directory${Platform.pathSeparator}$name';

String _stem(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
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
