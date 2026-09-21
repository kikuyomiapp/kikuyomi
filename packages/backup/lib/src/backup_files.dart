/// How backup files are named.
///
/// A backup folder is the user's own, and may hold anything: their other files, backups from another
/// app, copies a sync client made. The app recognises its backups by name alone, so the name has to be
/// unmistakably Kikuyomi's, and anything else is never listed, never restored from and never deleted.
///
/// A name is the time the backup was taken, in UTC to the millisecond:
/// `kikuyomi-backup-2026-09-14T15-30-12-345Z.kybackup`. Fixed-width fields make names sort by time as
/// plain text, which is how a file manager shows them. There are no colons, which Windows forbids in
/// names, and nothing else a platform treats specially, and the millisecond keeps two backups taken
/// in the same second apart.
library;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

const _prefix = 'kikuyomi-backup-';

/// What every backup file's name ends with.
const backupFileExtension = '.kybackup';

final _pattern = RegExp(
  r'^kikuyomi-backup-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z\.kybackup$',
);

/// The name of a backup taken at [createdAt].
///
/// Throws [ArgumentError] for a time outside the years 0 to 9999, which a name cannot hold.
String backupFileName(DateTime createdAt) {
  final t = createdAt.toUtc();
  if (t.year < 0 || t.year > 9999) {
    throw ArgumentError.value(createdAt, 'createdAt', 'is out of range');
  }
  String pad(int value, int width) => '$value'.padLeft(width, '0');
  return '$_prefix${pad(t.year, 4)}-${pad(t.month, 2)}-${pad(t.day, 2)}'
      'T${pad(t.hour, 2)}-${pad(t.minute, 2)}-${pad(t.second, 2)}'
      '-${pad(t.millisecond, 3)}Z$backupFileExtension';
}

/// When the backup named [fileName] was taken, or null when [fileName] is not the name of a backup
/// file: some other file, a partial one, or one renamed by the user or a sync client.
DateTime? backupTimeOf(String fileName) {
  final match = _pattern.firstMatch(fileName);
  if (match == null) return null;
  final [year, month, day, hour, minute, second, ms] = [
    for (var group = 1; group <= 7; group++) int.parse(match.group(group)!),
  ];
  final time = DateTime.utc(year, month, day, hour, minute, second, ms);
  // DateTime rolls an impossible date such as the 31st of September over into the next month, which
  // would give the same backup two names. Only the name it writes is one.
  return backupFileName(time) == fileName ? time : null;
}

/// Whether [fileName] is a backup file that was never finished, and was left long enough before [now]
/// that no write can still be under way.
///
/// A write that is cut short, by the app being ended mid-backup, leaves the file under its partial
/// name ([partialFileSuffix]). Nothing else removes it, and being named as the app's own, it is the
/// app's to remove.
bool isAbandonedBackupFile(String fileName, {required DateTime now}) {
  if (!fileName.endsWith(partialFileSuffix)) return false;
  final time = backupTimeOf(
    fileName.substring(0, fileName.length - partialFileSuffix.length),
  );
  return time != null && now.difference(time) > const Duration(days: 1);
}
