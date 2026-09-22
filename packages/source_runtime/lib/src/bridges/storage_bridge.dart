/// `storage`: one extension's own small key-value store (§3.5).
///
/// "Namespaced key-value store for preferences and small caches. Per-extension, size-capped;
/// secrets go to platform secure storage." SourceAPI 1.0 caps it at 1 MB per extension, which is
/// generous for a cookie-ish token or a cached category list and far too small to keep a library
/// in.
///
/// Where the values are really kept is the app's decision — Drift, a file, or nothing at all in a
/// test — so it sits behind [ExtensionStore]. What is here is the namespace, the cap, and the
/// refusal an extension gets when it reaches it, which is an error it can catch rather than a
/// silent loss.
library;

import 'dart:async';
import 'dart:convert';

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

import 'host_bridge.dart';

/// Where one extension's `storage` is kept. The app implements it.
///
/// Every method takes the extension's id, so that one implementation serves every extension and no
/// extension can name another's namespace: the key an extension passes never reaches the store on
/// its own.
abstract interface class ExtensionStore {
  /// Everything this extension has stored. Read once, when its runtime first touches `storage`.
  Future<Map<String, String>> readAll(String extensionId);

  /// Writes one value.
  Future<void> write(String extensionId, String key, String value);

  /// Removes one value. Removing what is not there is not a failure.
  Future<void> remove(String extensionId, String key);
}

/// A store that keeps everything in memory, for tests and for a runtime with nothing behind it.
final class InMemoryExtensionStore implements ExtensionStore {
  final _values = <String, Map<String, String>>{};

  /// What [extensionId] has stored, for a test to read or to seed.
  Map<String, String> of(String extensionId) =>
      _values.putIfAbsent(extensionId, () => {});

  @override
  Future<Map<String, String>> readAll(String extensionId) async =>
      Map.of(of(extensionId));

  @override
  Future<void> write(String extensionId, String key, String value) async =>
      of(extensionId)[key] = value;

  @override
  Future<void> remove(String extensionId, String key) async =>
      of(extensionId).remove(key);
}

/// The `storage` module of one extension's host API.
final class StorageBridge implements HostBridge {
  StorageBridge({
    required this.extensionId,
    required this.store,
    this.maxBytes = SourceLimits.maxStorageBytes,
  });

  /// The extension whose namespace this is.
  final String extensionId;

  final ExtensionStore store;

  /// The most this extension may keep, counting keys and values as UTF-8 (§3.5's size cap).
  final int maxBytes;

  /// What the store holds, read once and kept in step with every write.
  ///
  /// The cap cannot be applied without knowing the total, and reading everything back before each
  /// write would cost a call per `set`. Nothing else writes an extension's namespace, so one read
  /// is enough.
  Map<String, String>? _values;

  @override
  String get module => 'storage';

  @override
  Future<Object?> call(String method, List<Object?> arguments) async {
    final values = _values ??= await store.readAll(extensionId);
    switch (method) {
      case 'get':
        return values[_key(arguments)];
      case 'set':
        final key = _key(arguments);
        final value = arguments.stringAt(1, 'a value');
        final after = _size(values, replacing: key, with_: value);
        if (after > maxBytes) {
          throw HostCallException(
            'storage is full: this extension may keep ${maxBytes ~/ 1024} KB, and '
            '"$key" would take it to ${after ~/ 1024} KB',
          );
        }
        await store.write(extensionId, key, value);
        values[key] = value;
        return null;
      case 'remove':
        final key = _key(arguments);
        await store.remove(extensionId, key);
        values.remove(key);
        return null;
      default:
        throw HostCallException('there is no storage.$method');
    }
  }

  /// The key an extension asked for, held to the contract's length for a key.
  ///
  /// A key is what a namespace is made of, so an empty or enormous one is refused rather than
  /// trimmed: the extension would then be reading back something other than what it wrote.
  String _key(List<Object?> arguments) {
    final key = arguments.stringAt(0, 'a key');
    if (key.isEmpty || key.length > SourceLimits.maxKeyLength) {
      throw HostCallException(
        'a storage key is 1 to ${SourceLimits.maxKeyLength} characters',
      );
    }
    return key;
  }

  int _size(
    Map<String, String> values, {
    required String replacing,
    required String with_,
  }) {
    var total = utf8.encode(replacing).length + utf8.encode(with_).length;
    for (final entry in values.entries) {
      if (entry.key == replacing) continue;
      total += utf8.encode(entry.key).length + utf8.encode(entry.value).length;
    }
    return total;
  }
}
