import 'dart:async';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// §4.3's settings store, backed by `shared_preferences`.
///
/// Built on its cached store, which loads every key in [AppSettings.all] when it opens, so reads are
/// synchronous as [SettingsStore] promises. Values are stored as strings. Anything else found under a
/// key, such as a value some other build stored as a number, reads as not set.
final class SharedPreferencesSettingsStore implements SettingsStore {
  SharedPreferencesSettingsStore._(this._preferences);

  /// Opens the store, loading every setting.
  static Future<SharedPreferencesSettingsStore> open() async =>
      SharedPreferencesSettingsStore._(
        await SharedPreferencesWithCache.create(
          cacheOptions: SharedPreferencesWithCacheOptions(
            allowList: {for (final setting in AppSettings.all) setting.key},
          ),
        ),
      );

  final SharedPreferencesWithCache _preferences;

  final _written = StreamController<String>.broadcast(sync: true);

  @override
  T? read<T extends Object>(Setting<T> setting) =>
      switch (_preferences.get(setting.key)) {
        final String text => setting.decode(text),
        _ => null,
      };

  @override
  Future<void> write<T extends Object>(Setting<T> setting, T? value) async {
    // The cache changes before the returned future completes, so the listeners told below read the
    // new value.
    final written = value == null
        ? _preferences.remove(setting.key)
        : _preferences.setString(setting.key, setting.encode(value));
    _written.add(setting.key);
    await written;
  }

  @override
  Stream<T?> watch<T extends Object>(Setting<T> setting) =>
      Stream.multi((controller) {
        controller.add(read(setting));
        final subscription = _written.stream
            .where((key) => key == setting.key)
            .listen((_) => controller.add(read(setting)));
        controller.onCancel = subscription.cancel;
      });
}
