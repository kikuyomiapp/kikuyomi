import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// Where restoring from a backup has got to.
sealed class RestoreStep {
  const RestoreStep();
}

/// There is no folder to look in yet: the listener is asked to choose the one their backups are in.
final class RestoreChoosingFolder extends RestoreStep {
  const RestoreChoosingFolder({this.problem});

  /// Why the folder there was cannot be used, if that is why a folder is being asked for.
  final String? problem;
}

/// Reading the backups in a folder.
final class RestoreLooking extends RestoreStep {
  const RestoreLooking(this.folderName);

  final String folderName;
}

/// The backups in a folder, newest first, for choosing one.
final class RestoreChoosingBackup extends RestoreStep {
  const RestoreChoosingBackup(this.folderName, this.backups);

  final String folderName;
  final List<ListedBackup> backups;
}

/// Restoring [backup].
final class RestoreRestoring extends RestoreStep {
  const RestoreRestoring(this.backup);

  final RestorableBackup backup;
}

/// The restore is done.
final class RestoreDone extends RestoreStep {
  const RestoreDone(this.report);

  final RestoreReport report;
}

/// [backup] could not be restored, for [reason]; the library is as it was.
final class RestoreFailed extends RestoreStep {
  const RestoreFailed(this.backup, this.reason);

  final RestorableBackup backup;
  final String reason;
}

/// Restoring from a backup, a step at a time: finding the folder, choosing a backup in it, restoring
/// it. Shared by first-start setup and Settings.
///
/// A folder chosen to restore from becomes the folder backups go to, as a backup folder is the one
/// a restore on the next fresh install will look in.
class RestoreSession extends ChangeNotifier {
  /// [afterRestore] runs once a restore has succeeded, without holding up the report of it: the
  /// work start does for the library there was, such as looking for covers.
  RestoreSession({required this._backups, required this._afterRestore});

  final BackupService _backups;
  final Future<void> Function() _afterRestore;

  RestoreStep _step = const RestoreChoosingFolder();
  UserFolder? _folder;
  var _listed = const <ListedBackup>[];
  var _disposed = false;

  RestoreStep get step => _step;

  /// Looks in the backup folder already chosen, if there is one, and otherwise asks for one.
  Future<void> start() async {
    final folder = _backups.folder;
    if (folder == null) {
      _go(const RestoreChoosingFolder());
    } else {
      await showBackupsIn(folder);
    }
  }

  /// Shows the folder picker, keeps the folder chosen for backups, and lists the backups in it.
  /// Cancelling leaves things as they were.
  Future<void> chooseFolder() async {
    try {
      final folder = await _backups.chooseFolder();
      if (folder != null) await showBackupsIn(folder);
    } on FolderException catch (error) {
      _go(RestoreChoosingFolder(problem: error.message));
    }
  }

  /// Lists the backups in [folder].
  Future<void> showBackupsIn(UserFolder folder) async {
    _folder = folder;
    _go(RestoreLooking(folder.displayName));
    try {
      _listed = await _backups.listBackups(folder);
      _go(RestoreChoosingBackup(folder.displayName, _listed));
    } on FolderException catch (error) {
      _go(
        RestoreChoosingFolder(
          problem:
              'The folder ${folder.displayName} cannot be read: '
              '${error.message}',
        ),
      );
    }
  }

  /// Restores [backup], from the folder whose backups are listed.
  Future<void> restore(RestorableBackup backup) async {
    final folder = _folder;
    if (folder == null) return;
    _go(RestoreRestoring(backup));
    try {
      final report = await _backups.restore(folder, backup);
      unawaited(_afterRestore());
      _go(RestoreDone(report));
    } on BackupException catch (error) {
      _go(RestoreFailed(backup, error.message));
    } on FolderException catch (error) {
      _go(RestoreFailed(backup, error.message));
    } catch (error) {
      _go(RestoreFailed(backup, '$error'));
    }
  }

  /// Back to the list of backups, after one could not be restored.
  void backToBackups() {
    final folder = _folder;
    if (folder != null) _go(RestoreChoosingBackup(folder.displayName, _listed));
  }

  void _go(RestoreStep step) {
    _step = step;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
