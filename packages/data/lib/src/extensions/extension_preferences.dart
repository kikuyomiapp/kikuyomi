/// One extension's own storage, kept in the database (§3.5's `storage`, §4.3's
/// `extension_preference`).
///
/// SourceAPI 1.0 gives each extension a small key-value store for "preferences and small caches",
/// capped at 1 MB, and the cap is the runtime's business. This is only where the values are kept.
/// Until this table arrived they were kept in memory, so a source's chosen catalogue or its login
/// lasted until the app closed.
///
/// One row per key per extension, rather than a blob per extension, so that a write is a write of one
/// value and two extensions can never be in one row. Secrets do not belong here: §4.3 sends those to
/// platform secure storage, and the contract tells authors so.
library;

import 'package:drift/drift.dart';

import '../database/database.dart';

/// Where one extension's `storage` is kept, over Drift.
///
/// The app hands this to the extension runtime as its store. It takes the extension's id on every
/// call, exactly as the runtime's own interface does, so one store serves every extension and no
/// extension can name another's namespace.
final class ExtensionPreferenceStore {
  const ExtensionPreferenceStore(this._db);

  final KikuyomiDatabase _db;

  /// Everything [extensionId] has stored. The runtime reads this once, when the extension first
  /// touches `storage`.
  Future<Map<String, String>> readAll(String extensionId) async {
    final rows = await (_db.select(
      _db.extensionPreferences,
    )..where((p) => p.extensionId.equals(extensionId))).get();
    return {for (final row in rows) row.key: row.value};
  }

  /// Writes one value, replacing what was stored under [key].
  Future<void> write(String extensionId, String key, String value) => _db
      .into(_db.extensionPreferences)
      .insertOnConflictUpdate(
        ExtensionPreferencesCompanion.insert(
          extensionId: extensionId,
          key: key,
          value: value,
        ),
      );

  /// Removes one value. Removing what is not there is not a failure, as the contract has it.
  Future<void> remove(String extensionId, String key) async {
    await (_db.delete(_db.extensionPreferences)
          ..where((p) => p.extensionId.equals(extensionId) & p.key.equals(key)))
        .go();
  }

  /// Throws away everything [extensionId] stored, and returns how many values went.
  ///
  /// Not what uninstalling does — §3.9 keeps the listener's data — but what a listener who asks to
  /// clear an extension's data does.
  Future<int> clear(String extensionId) => (_db.delete(
    _db.extensionPreferences,
  )..where((p) => p.extensionId.equals(extensionId))).go();
}
