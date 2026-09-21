/// Finding the backups in a folder, to choose one to restore from.
library;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'backup_files.dart';
import 'codec.dart';

/// A backup file found in a folder.
sealed class ListedBackup {
  const ListedBackup({
    required this.fileName,
    required this.takenAt,
    this.sizeBytes,
  });

  final String fileName;

  /// When the backup was taken, as its name says.
  final DateTime takenAt;

  /// The file's size, where the folder says.
  final int? sizeBytes;
}

/// A backup this build can restore.
final class RestorableBackup extends ListedBackup {
  const RestorableBackup({
    required super.fileName,
    required super.takenAt,
    super.sizeBytes,
    required this.summary,
  });

  /// Who wrote it, when, and how many books it holds.
  final BackupSummary summary;
}

/// A file named as a backup that cannot be restored from: damaged, cut short, written by a newer app
/// in a form this build cannot restore, or not readable from the folder.
///
/// Listed rather than left out, so that a backup the user expected to see is explained instead of
/// missing.
final class UnrestorableBackup extends ListedBackup {
  const UnrestorableBackup({
    required super.fileName,
    required super.takenAt,
    super.sizeBytes,
    required this.problem,
  });

  /// A [BackupException], or a [FolderOperationException] when the file could not be read.
  final Exception problem;

  /// Whether updating the app would make the backup restorable.
  bool get needsNewerApp => problem is UnsupportedBackupVersionException;

  /// What is wrong, as a phrase for a person to read.
  String get reason => switch (problem) {
    BackupException(:final message) => message,
    FolderException(:final message) => message,
    final other => '$other',
  };
}

/// The backups in [folder], newest first.
///
/// Every file named as a backup is read, but only as far as [readBackupSummary] needs. Files not named
/// as backups are left out: they are not the app's.
///
/// Throws [FolderException] when the folder cannot be listed, or can no longer be reached while its
/// files are read. A single backup that cannot be read is listed as an [UnrestorableBackup], and the
/// rest are still listed.
Future<List<ListedBackup>> findBackups(UserFolder folder) async {
  final backups = [
    for (final file in await folder.list())
      if (backupTimeOf(file.name) case final takenAt?)
        (file: file, takenAt: takenAt),
  ]..sort((a, b) => b.takenAt.compareTo(a.takenAt));

  final listed = <ListedBackup>[];
  for (final (:file, :takenAt) in backups) {
    Exception? problem;
    try {
      final summary = readBackupSummary(await folder.read(file.name));
      if (summary.isRestorable) {
        listed.add(
          RestorableBackup(
            fileName: file.name,
            takenAt: takenAt,
            sizeBytes: file.sizeBytes,
            summary: summary,
          ),
        );
        continue;
      }
      problem = UnsupportedBackupVersionException(
        minReaderVersion: summary.minReaderVersion,
      );
    } on BackupException catch (error) {
      problem = error;
    } on FolderOperationException catch (error) {
      problem = error;
    }
    listed.add(
      UnrestorableBackup(
        fileName: file.name,
        takenAt: takenAt,
        sizeBytes: file.sizeBytes,
        problem: problem,
      ),
    );
  }
  return listed;
}
