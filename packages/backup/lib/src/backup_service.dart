/// Automatic backups to the folder the user chose: choosing it, writing a backup there, and restoring
/// from one.
///
/// §5.1 and ADR-0008 send backups to a user-chosen folder so that an Android uninstall or an iOS
/// re-sign loses nothing, and §8's Phase 1 asks for them to be automatic, with restore on a fresh
/// install. The format, the codec and the planner already exist in this package; this puts them
/// together with a folder and the settings that remember it. When to back up is the scheduler's
/// decision, and showing the results is the app's.
library;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'backup_and_restore.dart';
import 'backup_files.dart';
import 'backup_listing.dart';
import 'codec.dart';
import 'retention.dart';

/// What an attempt to back up came to. Failures are values the app can explain, never swallowed.
sealed class BackupOutcome {
  const BackupOutcome();
}

/// A backup was written.
final class BackupWritten extends BackupOutcome {
  const BackupWritten({
    required this.fileName,
    required this.takenAt,
    this.removed = const [],
    this.problems = const [],
  });

  final String fileName;
  final DateTime takenAt;

  /// Older backups deleted afterwards, by the retention rule.
  final List<String> removed;

  /// What went wrong after the backup itself was safely written: an old backup that could not be
  /// deleted, or the time not recorded. The backup is good; these are for reporting.
  final List<Object> problems;
}

/// No backup folder has been chosen, so nothing was written.
final class BackupNotConfigured extends BackupOutcome {
  const BackupNotConfigured();
}

/// The backup folder can no longer be reached, so nothing was written. Choosing it again fixes this.
final class BackupFolderUnreachable extends BackupOutcome {
  const BackupFolderUnreachable(this.reason);

  /// Why, as a phrase for a person to read.
  final String reason;
}

/// The backup could not be taken or written, so nothing was.
final class BackupFailed extends BackupOutcome {
  const BackupFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  /// What went wrong, as a phrase for a person to read.
  String get reason => switch (error) {
    FolderException(:final message) => message,
    final other => '$other',
  };
}

/// Backups of the library, in the folder the settings remember.
final class BackupService {
  BackupService({
    required LibrarySnapshotReader library,
    required RestoreWriter restorer,
    required UserFolders folders,
    required SettingsStore settings,
    required Clock clock,
    required String appVersion,
    required String deviceId,
    DateTime Function(DateTime instant)? localTime,
  }) : _library = library,
       _restorer = restorer,
       _folders = folders,
       _settings = settings,
       _clock = clock,
       _appVersion = appVersion,
       _deviceId = deviceId,
       _localTime = localTime;

  final LibrarySnapshotReader _library;
  final RestoreWriter _restorer;
  final UserFolders _folders;
  final SettingsStore _settings;
  final Clock _clock;
  final String _appVersion;
  final String _deviceId;

  /// Local time for retention's calendar days; the device's unless a test gives another.
  final DateTime Function(DateTime instant)? _localTime;

  /// Whether this device can choose a backup folder at all.
  bool get canChooseFolder => _folders.canChoose;

  /// The folder backups go to, or null before one is chosen.
  UserFolder? get folder => _open(_settings.read(AppSettings.backupFolder));

  /// The folder backups go to, now and whenever another is chosen.
  Stream<UserFolder?> watchFolder() =>
      _settings.watch(AppSettings.backupFolder).map(_open);

  /// When the last backup was written, now and after every backup.
  Stream<DateTime?> watchLastBackup() =>
      _settings.watch(AppSettings.lastBackupAt);

  UserFolder? _open(String? handle) =>
      handle == null ? null : _folders.open(handle);

  /// Shows the folder picker, and makes the folder chosen the one backups go to. Returns it, or null
  /// when the user cancels, which leaves the folder there was.
  ///
  /// Throws [FolderUnsupportedException] where [canChooseFolder] is false.
  Future<UserFolder?> chooseFolder() async {
    final chosen = await _folders.choose();
    if (chosen != null) {
      await _settings.write(AppSettings.backupFolder, chosen.handle);
    }
    return chosen;
  }

  /// Writes a backup of the library to the backup folder, then deletes the backups retention no
  /// longer keeps, and records when it was written.
  ///
  /// Never throws: every way it can fail is a [BackupOutcome].
  Future<BackupOutcome> backUp() async {
    final folder = this.folder;
    if (folder == null) return const BackupNotConfigured();

    // One time for both the file's name and the time inside it.
    final takenAt = _clock.now();
    final name = backupFileName(takenAt);
    try {
      final bytes = await createBackup(
        _library,
        clock: _FixedClock(takenAt),
        appVersion: _appVersion,
        deviceId: _deviceId,
      );
      await folder.write(name, bytes);
    } on FolderUnavailableException catch (error) {
      return BackupFolderUnreachable(error.message);
    } catch (error, stackTrace) {
      return BackupFailed(error, stackTrace);
    }

    final problems = <Object>[];
    try {
      await _settings.write(AppSettings.lastBackupAt, takenAt);
    } catch (error) {
      problems.add(error);
    }

    final removed = <String>[];
    try {
      final names = [for (final file in await folder.list()) file.name];
      final now = _clock.now();
      final localTime = _localTime;
      final expired = {
        ...localTime == null
            ? backupsToDelete(names, now: now)
            : backupsToDelete(names, now: now, localTime: localTime),
        for (final name in names)
          if (isAbandonedBackupFile(name, now: now)) name,
      }..remove(name);
      for (final expiredName in expired) {
        try {
          await folder.delete(expiredName);
          removed.add(expiredName);
        } on FolderException catch (error) {
          problems.add(error);
        }
      }
    } on FolderException catch (error) {
      problems.add(error);
    }

    return BackupWritten(
      fileName: name,
      takenAt: takenAt,
      removed: List.unmodifiable(removed),
      problems: List.unmodifiable(problems),
    );
  }

  /// The backups in [folder], newest first, as [findBackups] lists them.
  Future<List<ListedBackup>> listBackups(UserFolder folder) =>
      findBackups(folder);

  /// Restores [backup], found in [folder], into the library.
  ///
  /// Throws [FolderException] when the file cannot be read, and [BackupException] when it cannot be
  /// restored from, leaving the library as it was.
  Future<RestoreReport> restore(UserFolder folder, ListedBackup backup) async =>
      restoreBackup(await folder.read(backup.fileName), library: _restorer);
}

/// A clock stopped at one moment.
final class _FixedClock implements Clock {
  const _FixedClock(this._now);

  final DateTime _now;

  @override
  DateTime now() => _now;
}
