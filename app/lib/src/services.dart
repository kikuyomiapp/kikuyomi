import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';
import 'package:path_provider/path_provider.dart';

/// The composition root (§2.8): the one place concrete implementations are chosen and wired
/// together. Everything below the app works against interfaces.
final class AppServices {
  AppServices._({
    required this.database,
    required this.coordinator,
    required this.clock,
  });

  static Future<AppServices> open() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final database = KikuyomiDatabase(
      // §2.7: the database runs in a background isolate, so queries never block a frame.
      NativeDatabase.createInBackground(
        File(_join(directory.path, 'kikuyomi.sqlite')),
      ),
    );
    const clock = SystemClock();
    final coordinator = PlaybackCoordinator(
      engine: JustAudioEngine(),
      resolver: LocalMediaResolver(database),
      store: DriftPlaybackStore(
        database,
        deviceId: await _deviceId(directory),
        clock: clock,
      ),
      clock: clock,
    );
    return AppServices._(
      database: database,
      coordinator: coordinator,
      clock: clock,
    );
  }

  final KikuyomiDatabase database;
  final PlaybackCoordinator coordinator;
  final Clock clock;

  /// Reads an MP4 or M4B at [path] and adds it to the library, returning the book's id.
  Future<int> importM4b(String path) async {
    final file = File(path).absolute;
    final source = await FileByteSource.open(file);
    try {
      final info = await readMp4Info(source);
      if (info == null) {
        throw FormatException('${file.path} is not an MP4 or M4B file');
      }
      return await importLocalBook(
        database,
        LocalBookImport(
          file: LocalBookFile(
            path: file.path,
            durationMs: info.durationMs,
            sizeBytes: source.length,
            format: _extension(file.path),
            markers: [
              for (final chapter
                  in info.chapters?.chapters ?? const <Mp4Chapter>[])
                TimelineMarker(title: chapter.title, startMs: chapter.startMs),
            ],
          ),
          title: info.title ?? info.album ?? _stem(file.path),
          authors: [?info.artist],
          narrators: [?info.composer],
        ),
        clock: clock,
      );
    } finally {
      await source.close();
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
