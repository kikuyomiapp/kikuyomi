import 'dart:async';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// Settings kept in a map, standing in for `shared_preferences`.
final class InMemorySettingsStore implements SettingsStore {
  /// A store already holding [stored], as text by key, the way a real store holds it.
  InMemorySettingsStore([Map<String, String> stored = const {}])
    : stored = {...stored};

  /// What is stored, by key. Tests may look, or change it to set up a case.
  final Map<String, String> stored;

  final _written = StreamController<String>.broadcast(sync: true);

  @override
  T? read<T extends Object>(Setting<T> setting) =>
      switch (stored[setting.key]) {
        final text? => setting.decode(text),
        null => null,
      };

  @override
  Future<void> write<T extends Object>(Setting<T> setting, T? value) async {
    if (value == null) {
      stored.remove(setting.key);
    } else {
      stored[setting.key] = setting.encode(value);
    }
    _written.add(setting.key);
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
