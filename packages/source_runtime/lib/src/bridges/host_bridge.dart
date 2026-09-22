/// The host API an extension can reach, and nothing else (§3.5).
///
/// "The host API is intentionally small. Everything not listed is impossible." An extension cannot
/// touch the filesystem, the library, another extension's data or any device API; it has `http`,
/// `html`, `crypto`, `storage`, `log` and `host`, each implemented here and each bounded. This
/// narrowness is a security decision: extension code comes from third parties the listener may
/// barely know.
///
/// Every module is a [HostBridge] behind an interface, so that a test can substitute one and so
/// that the parts of a bridge that belong to the app — where storage is kept, which console the log
/// goes to — stay in the app.
library;

import 'dart:async';

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart' as contract;

/// One module of the host API: `http`, `html`, `crypto`, `storage` or `log`.
///
/// A bridge is called from the isolate its runtime lives in, with whatever the prelude's shim
/// passed. It validates its own arguments: they come from an extension, so they are untrusted,
/// however plausible the shim above them looks.
abstract interface class HostBridge {
  /// The name the prelude calls this module by.
  String get module;

  /// Answers one call. Returning a `Future` gives the extension a promise.
  FutureOr<Object?> call(String method, List<Object?> arguments);
}

/// What a bridge throws when an extension asks for something it may not have, or asks wrongly.
///
/// It reaches the script as a JavaScript `Error` with this message, so an extension can catch it,
/// and it is the extension's own mistake to see. A bridge failing is never the app's failure: the
/// call carries on inside the extension.
final class HostCallException implements Exception {
  const HostCallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A failure that reaches the extension as one of the contract's error kinds.
///
/// A bridge that throws reaches JavaScript as a plain `Error` with a message, and the kind is lost:
/// the binding turns a Dart exception into its text. That is right for an extension's own mistake,
/// which is a mistake and nothing more, but wrong for a site that could not be reached — the
/// contract says `http.fetch` throws `Network` for that, and an extension catches it by kind.
///
/// So a bridge returns this instead of throwing, and the prelude turns it back into an error
/// carrying its `kind`, which the extension can catch and which, if it does not, arrives at the app
/// as that kind.
Map<String, Object?> hostError(String kind, String message) => {
  hostErrorMarker: {'kind': kind, 'message': message},
};

/// The field the prelude recognises a [hostError] by.
const hostErrorMarker = '__kikuyomiError';

/// Everything the `host` module tells an extension, and the `kikuyomi` object is built from.
///
/// `host` is synchronous and read-only (§3.5), so it is data handed to the runtime as it starts
/// rather than a bridge that answers calls.
final class HostFacts {
  const HostFacts({required this.appVersion, this.features = const {}});

  /// The app's own version, as the manifest's `minAppVersion` is compared against.
  final String appVersion;

  /// Optional host features this app has, for `host.has(feature)`. An extension asks rather than
  /// assuming, which is what keeps minor versions additive (§3.7).
  final Set<String> features;

  /// The contract version this app implements.
  String get apiVersion => contract.apiVersion;

  /// As the prelude reads it.
  Map<String, Object?> toPlainData() => {
    'apiVersion': apiVersion,
    'appVersion': appVersion,
    'features': features.toList()..sort(),
  };
}

/// The modules of one extension's host API, and the one function the prelude reaches them through.
final class HostApi {
  HostApi(Iterable<HostBridge> bridges)
    : _bridges = {for (final bridge in bridges) bridge.module: bridge};

  final Map<String, HostBridge> _bridges;

  /// The global the engine installs; the prelude captures it and deletes the global.
  static const entryPoint = '__kikuyomiHostCall';

  /// Dispatches `__kikuyomiHostCall(module, method, args)`.
  ///
  /// The arguments come from JavaScript, so they are checked rather than trusted: a script that
  /// reached this with anything but a module name, a method name and a list gets an error.
  FutureOr<Object?> dispatch(List<Object?> arguments) {
    final module = arguments.isEmpty ? null : arguments[0];
    final method = arguments.length < 2 ? null : arguments[1];
    final rest = arguments.length < 3 ? null : arguments[2];
    if (module is! String || method is! String) {
      throw const HostCallException('a host call names a module and a method');
    }
    final bridge = _bridges[module];
    if (bridge == null) {
      throw HostCallException('there is no host module "$module"');
    }
    return bridge.call(method, switch (rest) {
      null => const [],
      final List<Object?> list => list,
      _ => throw HostCallException(
        '$module.$method takes its arguments as an array',
      ),
    });
  }
}

/// Reads one argument of a host call, saying which call it belongs to when it is wrong.
extension HostArguments on List<Object?> {
  /// The argument at [index] as a string.
  String stringAt(int index, String what) {
    final value = index < length ? this[index] : null;
    if (value is String) return value;
    throw HostCallException('$what is a string');
  }

  /// The argument at [index] as a string, or null when it was left out.
  String? optionalStringAt(int index, String what) {
    final value = index < length ? this[index] : null;
    if (value == null) return null;
    if (value is String) return value;
    throw HostCallException('$what is a string');
  }

  /// The argument at [index] as a whole number.
  int intAt(int index, String what) {
    final value = index < length ? this[index] : null;
    if (value is int) return value;
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      return value.toInt();
    }
    throw HostCallException('$what is a whole number');
  }

  /// The argument at [index] as an object.
  Map<Object?, Object?> objectAt(int index, String what) {
    final value = index < length ? this[index] : null;
    if (value is Map) return value;
    throw HostCallException('$what is an object');
  }
}
