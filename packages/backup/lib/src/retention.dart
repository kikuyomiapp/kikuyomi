/// Which automatic backups to keep.
///
/// Backups are written shortly after every change, so a folder would fill without a limit. The rule
/// keeps what a restore could want: the last few backups, for undoing something just done, and one
/// from each recent day, for going back further than a morning's listening.
library;

import 'backup_files.dart';

/// The backups named in [fileNames] to delete at [now].
///
/// Kept are the [newest] backups, and the newest backup from each of the past [days] local calendar
/// days, today included. Every other backup is deleted. A name that is not a backup's is never in the
/// result, however old the file is, because the app did not write it.
///
/// Days are local, as the user sees them: a backup taken just after midnight belongs to the new day.
/// [localTime] gives an instant's local date and time; it is the device's time zone unless a test
/// gives another. A backup dated after [now], by a device whose clock was wrong, counts towards
/// [newest] but belongs to no past day.
///
/// Pure, so the rule is tested without a folder.
List<String> backupsToDelete(
  Iterable<String> fileNames, {
  required DateTime now,
  DateTime Function(DateTime instant) localTime = _deviceLocalTime,
  int newest = 3,
  int days = 7,
}) {
  final backups = [
    for (final name in fileNames)
      if (backupTimeOf(name) case final time?) (name: name, time: time),
  ]..sort((a, b) => b.time.compareTo(a.time));

  final keep = {for (final backup in backups.take(newest)) backup.name};
  final today = _dayNumber(localTime(now));
  final daysKept = <int>{};
  // Newest first, so the first backup seen on a day is that day's newest.
  for (final backup in backups) {
    final day = _dayNumber(localTime(backup.time));
    final age = today - day;
    if (age >= 0 && age < days && daysKept.add(day)) keep.add(backup.name);
  }

  return [
    for (final backup in backups)
      if (!keep.contains(backup.name)) backup.name,
  ];
}

DateTime _deviceLocalTime(DateTime instant) => instant.toLocal();

/// The calendar date of [local]'s fields, as a count of days, so that dates can be subtracted. Built
/// in UTC, where every day is 24 hours long, so a daylight saving change never skews the count.
int _dayNumber(DateTime local) =>
    DateTime.utc(local.year, local.month, local.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;
