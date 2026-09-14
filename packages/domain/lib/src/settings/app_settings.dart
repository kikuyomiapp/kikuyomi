import 'settings_store.dart';

/// What became of the offer, made when the app first starts with an empty library, to choose a
/// backup folder or restore from one (§5.1).
enum BackupSetup {
  /// A folder was chosen, or a backup restored from one.
  completed,

  /// The listener chose to go without for now. Home keeps reminding them until a folder is chosen.
  skipped,
}

/// Every setting the app keeps, in one place, as §4.3 asks.
///
/// §4.3 also says that preferences which should survive a restore are included in backups
/// explicitly. None of the settings so far should be:
///
/// - [backupFolder] is a permission granted to this installation. Android's tree permissions and
///   iOS's bookmarks mean nothing to another device, or to the same device after a reinstall.
/// - [lastBackupAt] and [backupDue] describe this installation's own backups.
/// - [backupSetup] is this installation's first start.
///
/// The preferences still to come that shape listening, such as skip intervals, smart rewind and a
/// default speed, should be carried. When one arrives it gets a field in `proto/backup.proto`, whose
/// header already expects them, and a note here saying so.
abstract final class AppSettings {
  /// The folder automatic backups are written to, as the serialised handle a `UserFolders`
  /// implementation gave for it. Not set until the listener chooses one.
  static const backupFolder = Setting<String>(
    'backup.folder',
    encode: _text,
    decode: _text,
  );

  /// When the last backup was successfully written.
  static const lastBackupAt = Setting<DateTime>(
    'backup.lastWrittenAt',
    encode: _encodeTime,
    decode: _decodeTime,
  );

  /// Whether the library has changed since the last backup was written.
  ///
  /// Kept here rather than only in memory, so that changes made just before the app was ended
  /// without warning are still backed up after it next starts.
  static const backupDue = Setting<bool>(
    'backup.due',
    encode: _encodeFlag,
    decode: _decodeFlag,
  );

  /// Whether the first-start offer to set up backups was taken or skipped. Not set until one or the
  /// other.
  static const backupSetup = Setting<BackupSetup>(
    'backup.setup',
    encode: _encodeSetup,
    decode: _decodeSetup,
  );

  /// Every setting above. A store that has to be told its keys in advance, as `shared_preferences`'
  /// cached store does, is told these.
  static const all = <Setting<Object>>[
    backupFolder,
    lastBackupAt,
    backupDue,
    backupSetup,
  ];
}

String _text(String value) => value;

String _encodeTime(DateTime time) => '${time.millisecondsSinceEpoch}';

/// Throws [ArgumentError] for a time `DateTime` cannot hold, which reads as not set.
DateTime? _decodeTime(String stored) => switch (int.tryParse(stored)) {
  final ms? => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
  null => null,
};

String _encodeFlag(bool value) => '$value';

bool? _decodeFlag(String stored) => switch (stored) {
  'true' => true,
  'false' => false,
  _ => null,
};

String _encodeSetup(BackupSetup setup) => setup.name;

BackupSetup? _decodeSetup(String stored) =>
    BackupSetup.values.asNameMap()[stored];
