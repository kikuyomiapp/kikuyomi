import 'package:flutter/material.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';

/// "1 book", "3 books".
String countBooks(int count) => count == 1 ? '1 book' : '$count books';

/// When a backup was taken, as a person reads it: the local day, with the year, and the time.
String formatBackupTime(BuildContext context, DateTime time) {
  final local = time.toLocal();
  final words = MaterialLocalizations.of(context);
  final clock = words.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return '${words.formatMediumDate(local)}, ${local.year} at $clock';
}

/// What an attempt to back up came to, in a sentence.
String describeBackupOutcome(BackupOutcome outcome) => switch (outcome) {
  BackupWritten() => 'Backed up',
  BackupNotConfigured() => 'Choose a backup folder first',
  BackupFolderUnreachable(:final reason) =>
    'The backup folder can no longer be reached: $reason',
  BackupFailed(:final reason) => 'Could not back up: $reason',
};

/// What a restore did, a sentence at a time. Books are counted as the list of backups counts them:
/// those in the library.
List<String> describeRestore(RestoreReport report) {
  final plan = report.plan;
  final added = plan.newBooks.where((book) => book.inLibrary).length;
  final updated = plan.mergedBooks.length;
  final sentences = [
    if (plan.isEmpty) 'Your library already had everything in this backup.',
    if (added > 0) 'Added ${countBooks(added)} to your library.',
    if (updated > 0) 'Brought ${countBooks(updated)} up to date.',
  ];
  return sentences.isEmpty ? ['Restored the backup.'] : sentences;
}
