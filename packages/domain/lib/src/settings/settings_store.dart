/// App preferences, behind an interface: §4.3's "typed settings store backed by `shared_preferences`,
/// with keys defined in one place".
///
/// Preferences are not user data. The library, progress and everything else the user owns live in
/// the database, which stays the single source of truth (§2.6). What lives here is how this
/// installation of the app is set up, such as the folder it writes backups to. Every key is declared
/// in `AppSettings`.
///
/// The interface sits in the domain because the pure packages that read and write settings, such as
/// `backup`, may not depend on the platform adapters that implement it (§2.4), the same arrangement
/// as `PlaybackStore`.
library;

/// One setting: the key it is stored under, and how its value is written there.
///
/// Values are stored as text, which every backing store can hold. A stored value that does not read
/// back as a [T] reads as not set: it may have been written by a build that kept something else
/// under the key, or edited by hand, and a preference is never worth failing over.
final class Setting<T extends Object> {
  const Setting(
    this.key, {
    required String Function(T value) encode,
    required T? Function(String stored) decode,
  }) : _encode = encode,
       _decode = decode;

  /// Unique among `AppSettings`.
  final String key;

  final String Function(T value) _encode;
  final T? Function(String stored) _decode;

  /// [value] as stored.
  String encode(T value) => _encode(value);

  /// The value [stored] holds, or null when it holds none this build can read.
  T? decode(String stored) {
    try {
      return _decode(stored);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}

/// Where settings are kept.
///
/// Reads are synchronous: a store loads every setting when it opens, so that a screen deciding what
/// to show at start never waits on storage. Writes are asynchronous, and a read made after a write
/// has been started already sees the new value.
abstract interface class SettingsStore {
  /// The value of [setting], or null when it is not set.
  T? read<T extends Object>(Setting<T> setting);

  /// Sets [setting] to [value], or clears it when [value] is null.
  Future<void> write<T extends Object>(Setting<T> setting, T? value);

  /// The value of [setting] now, and again after every write to it.
  Stream<T?> watch<T extends Object>(Setting<T> setting);
}
