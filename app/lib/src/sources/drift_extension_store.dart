import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';

/// An extension's `storage` (§3.5), kept in the database.
///
/// The runtime declares what it needs as [ExtensionStore]; the table and the queries are `data`'s
/// (§4.3's `extension_preference`). Neither package knows the other — `data` holds no extension
/// runtime and the runtime holds no database — so the two meet here, in the composition root, which is
/// where §2.8 puts a choice of implementation.
///
/// The 1 MB cap SourceAPI 1.0 gives an extension is the bridge's, not this store's: how much an
/// extension may keep is part of the contract, and where it is kept is not.
final class DriftExtensionStore implements ExtensionStore {
  DriftExtensionStore(KikuyomiDatabase database)
    : _preferences = ExtensionPreferenceStore(database);

  final ExtensionPreferenceStore _preferences;

  @override
  Future<Map<String, String>> readAll(String extensionId) =>
      _preferences.readAll(extensionId);

  @override
  Future<void> write(String extensionId, String key, String value) =>
      _preferences.write(extensionId, key, value);

  @override
  Future<void> remove(String extensionId, String key) =>
      _preferences.remove(extensionId, key);
}
