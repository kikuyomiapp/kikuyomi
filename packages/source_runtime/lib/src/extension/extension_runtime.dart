/// One extension's runtime: its code, its host API, and the calls into it (§3.6).
///
/// "A `JsSourceAdapter` implements the Dart `ContentSource` interface by forwarding calls to an
/// `ExtensionRuntime`: one QuickJS runtime and context per extension (not per source), created on
/// first use inside one of the worker isolates and confined to it."
///
/// This is the protocol half of that: the prelude and the bundle are evaluated in a runtime, the
/// extension's default export is found, and each call goes through one function in the prelude
/// that never throws — it answers with `{ ok: true, value }` or `{ ok: false, error }`. Nothing is
/// thrown across the boundary on purpose: the binding turns a thrown JavaScript `Error` into its
/// text, which would lose the `kind` the app reacts to (SourceAPI 1.0, "Errors"). As data, the kind
/// survives.
library;

import 'dart:async';
import 'dart:convert';

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

import '../bridges/host_bridge.dart';
import '../engine/script_engine.dart';
import 'js_source_adapter.dart';
import 'prelude.dart';

/// One extension's code, as the manager unpacked it, and what it is allowed to reach.
final class ExtensionBundle {
  const ExtensionBundle({
    required this.extensionId,
    required this.code,
    required this.domains,
  });

  /// The manifest's `id`, for the console and for storage's namespace.
  final String extensionId;

  /// `main.js`: one bundled ES2020 file, no imports (§3.3).
  final String code;

  /// Every URL this extension may fetch or hand the app, from its manifest's `domains`.
  final DomainAllowlist domains;
}

/// An extension that could not be loaded: its code did not run, or it exports no sources.
///
/// This is not a [SourceException]: no call was made. The manager marks such an extension broken
/// rather than showing a listener a failed search.
final class ExtensionLoadException implements Exception {
  const ExtensionLoadException(this.extensionId, this.message);

  final String extensionId;
  final String message;

  @override
  String toString() =>
      'the extension $extensionId could not be loaded: $message';
}

/// A bridge that keeps something for the length of one call, and is told when that call is over.
///
/// The html bridge parses documents an extension then walks; nothing in the contract frees one, so
/// the runtime says when a call has finished and they can go.
abstract interface class CallScopedBridge {
  void endOfCall();
}

/// One extension, loaded in one runtime.
final class ExtensionRuntime implements ExtensionCalls {
  ExtensionRuntime._({
    required ScriptEngine engine,
    required ExtensionBundle bundle,
    required List<HostBridge> bridges,
  }) : _engine = engine,
       _bundle = bundle,
       _bridges = bridges,
       _decoder = PlainDataDecoder(bundle.domains);

  /// Loads [bundle] into [engine] and reads its sources.
  ///
  /// The order matters: the host function first, so the prelude can capture and hide it; the host's
  /// facts next, because `host` is synchronous and the prelude builds it from them; then the
  /// prelude, which is the whole environment the extension runs in (§3.5); then the extension.
  ///
  /// Throws [ExtensionLoadException] for anything that goes wrong, including an extension that
  /// spends its whole deadline in its top-level code.
  static Future<ExtensionRuntime> load({
    required ScriptEngine engine,
    required ExtensionBundle bundle,
    required HostFacts host,
    Iterable<HostBridge> bridges = const [],
    Duration? deadline,
  }) async {
    final all = List<HostBridge>.unmodifiable([
      ...bridges,
      const _TimerBridge(),
      _UrlBridge(bundle.domains),
    ]);
    final runtime = ExtensionRuntime._(
      engine: engine,
      bundle: bundle,
      bridges: all,
    );
    final api = HostApi(all);
    try {
      engine.defineHostFunction(HostApi.entryPoint, api.dispatch);
      await engine.evaluate(
        'globalThis.__kikuyomiHostInfo = ${jsonEncode(host.toPlainData())};',
        name: '<host>',
        deadline: deadline,
      );
      await engine.evaluate(
        kikuyomiPrelude,
        name: 'kikuyomi-prelude.js',
        deadline: deadline,
      );
      await engine.evaluate(
        _wrap(bundle.code),
        name: '${bundle.extensionId}/main.js',
        deadline: deadline,
      );
      final keys = await engine.call(
        '__kikuyomiRuntime.sourceKeys',
        const [],
        deadline: deadline,
      );
      runtime._sourceKeys = List<String>.unmodifiable(
        keys is List ? keys.whereType<String>() : const <String>[],
      );
    } on ScriptException catch (error) {
      throw ExtensionLoadException(bundle.extensionId, error.toString());
    }
    return runtime;
  }

  /// The bundle inside the wrapper that finds its default export.
  ///
  /// §3.3's bundle is "a single bundled ES2020 file, no imports", produced by the SDK's CLI, whose
  /// default export names the sources. A script cannot have an export, so the bundler writes one of
  /// the three shapes bundlers write, and all three are read here: `module.exports`, its `default`
  /// for an ES module compiled to CommonJS, and a global for an IIFE bundle. The trailing newline
  /// matters: a bundle ending in a `//` comment would otherwise swallow the closing brace.
  static String _wrap(String code) =>
      '''
__kikuyomiRuntime.setExtension((function () {
  var module = { exports: {} };
  var exports = module.exports;
  (function (module, exports) {
$code
  })(module, exports);
  return module.exports;
})());
''';

  final ScriptEngine _engine;
  final ExtensionBundle _bundle;
  final List<HostBridge> _bridges;
  final PlainDataDecoder _decoder;

  List<String> _sourceKeys = const [];
  var _disposed = false;

  /// The manifest's `id` of the extension in this runtime.
  @override
  String get extensionId => _bundle.extensionId;

  /// The source keys the extension really declares, which the manager checks against the manifest.
  List<String> get sourceKeys => _sourceKeys;

  /// The decoder every result of this extension is read with, built from its own domains.
  ///
  /// The adapter decodes with it rather than with one of its own, so that one extension's URL rule
  /// is applied in exactly one place.
  PlainDataDecoder get decoder => _decoder;

  /// Whether `sources[sourceKey]` has [method], for the optional methods a screen reads as
  /// capabilities before it offers a Latest tab or a filter button.
  @override
  Future<bool> hasMethod(String sourceKey, String method) async {
    final answer = await _call('__kikuyomiRuntime.hasMethod', [
      sourceKey,
      method,
    ], null);
    return answer == true;
  }

  /// Calls `sources[sourceKey][method](...arguments)` and returns its result as plain data.
  ///
  /// [arguments] are already encoded by `source_api`'s encoders. The result is not decoded here:
  /// that is [JsSourceAdapter]'s work, with the decoder that holds it to the contract's rules.
  ///
  /// Throws a [SourceException]: the kind the extension threw, or the kind the failure amounts to.
  @override
  Future<Object?> invoke(
    String sourceKey,
    String method,
    List<Object?> arguments, {
    Duration? deadline,
  }) async {
    final answer = await _call('__kikuyomiRuntime.invoke', [
      sourceKey,
      method,
      arguments,
    ], deadline);
    if (answer is! Map) {
      throw ParseException(
        'the extension answered $method with ${_describe(answer)} instead of a result',
      );
    }
    if (answer['ok'] == true) return answer['value'];
    throw _decoder.decodeError(answer['error']);
  }

  Future<Object?> _call(
    String function,
    List<Object?> arguments,
    Duration? deadline,
  ) async {
    if (_disposed) {
      throw const ParseException('the extension has been unloaded');
    }
    try {
      return await _engine.call(function, arguments, deadline: deadline);
    } on ScriptException catch (error) {
      throw _asSourceException(error);
    } finally {
      for (final bridge in _bridges) {
        if (bridge case final CallScopedBridge scoped) scoped.endOfCall();
      }
    }
  }

  /// Frees the runtime. Nothing can be called afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final bridge in _bridges) {
      if (bridge case final CallScopedBridge scoped) scoped.endOfCall();
    }
    await _engine.dispose();
  }

  /// What a failure of the engine itself amounts to for the caller.
  ///
  /// The contract's kinds are the ones an extension throws, and none of them is "the watchdog
  /// stopped it". [ParseException] is the kind the contract makes the catch-all — "anything else
  /// thrown, including a plain `Error`, is treated as `Parse`" — so that is what these become, with
  /// a message that says which limit was reached. The kinds that matter for an extension's health
  /// are not lost: the [ScriptException] is what §3.6's "marked unhealthy and disabled" will count,
  /// and it is the runtime, not the source call, that will count them.
  SourceException _asSourceException(ScriptException error) => switch (error) {
    ScriptDeadlineException(:final deadline) => ParseException(
      'the extension did not answer within ${deadline.inSeconds} s and was stopped',
    ),
    ScriptMemoryException(:final limitBytes) => ParseException(
      'the extension asked for more than ${limitBytes ~/ (1024 * 1024)} MB of memory '
      'and was stopped',
    ),
    ScriptCancelledException() => const ParseException(
      'the call was stopped before it finished',
    ),
    ScriptEngineException(:final message) => ParseException(
      'the extension runtime failed: $message',
    ),
    ScriptThrewException(:final message) => ParseException(message),
  };
}

String _describe(Object? value) => switch (value) {
  null => 'nothing',
  final String text =>
    '"${text.length > 40 ? '${text.substring(0, 40)}…' : text}"',
  final List<Object?> list => 'an array of ${list.length}',
  _ => '$value',
};

/// `setTimeout`, as the prelude asks the host for it.
///
/// QuickJS has no timers of its own: they are not part of the language. The prelude keeps the
/// callbacks and asks here only to be told when the time has passed, so a timer is one promise and
/// nothing of the extension's crosses the boundary. A call's deadline bounds the wait, as it bounds
/// everything else the call does.
final class _TimerBridge implements HostBridge {
  const _TimerBridge();

  @override
  String get module => 'timer';

  @override
  FutureOr<Object?> call(String method, List<Object?> arguments) {
    if (method != 'sleep') {
      throw HostCallException('there is no timer.$method');
    }
    final ms = arguments.intAt(0, 'a delay');
    // A negative or absurd delay is the extension's arithmetic, not a reason to fail its call. The
    // deadline decides how long a wait may really be.
    final wait = ms < 0 ? 0 : ms;
    return Future<Object?>.delayed(Duration(milliseconds: wait), () => null);
  }
}

/// `new URL(...)`, parsed by the host.
///
/// The prelude could parse URLs in JavaScript, but then two parsers would read one string, and
/// SourceAPI 1.0 says why that must not happen: "What the app fetches is the URL as it parsed it,
/// never the extension's text: two parsers can read one string differently, and handing on the
/// parsed form keeps the host that was checked the host that is contacted." The parser here is the
/// one that later checks the URL against the extension's domains.
final class _UrlBridge implements HostBridge {
  const _UrlBridge(this.domains);

  /// Only for the message when a URL is not one at all; `URL` itself is not the allowlist. An
  /// extension may build a URL it is not allowed to fetch, and finds out when it fetches it.
  final DomainAllowlist domains;

  @override
  String get module => 'url';

  @override
  FutureOr<Object?> call(String method, List<Object?> arguments) {
    if (method != 'parse') {
      throw HostCallException('there is no url.$method');
    }
    final text = arguments.stringAt(0, 'a URL');
    final base = arguments.optionalStringAt(1, 'a base URL');
    final Uri parsed;
    try {
      final relative = Uri.parse(text);
      parsed = base == null ? relative : Uri.parse(base).resolveUri(relative);
    } on FormatException {
      // The prelude turns null into the TypeError the web platform throws.
      return null;
    }
    if (!parsed.hasScheme) return null;
    return {
      'href': parsed.toString(),
      'protocol': '${parsed.scheme}:',
      'username': parsed.userInfo.split(':').first,
      'password': parsed.userInfo.contains(':')
          ? parsed.userInfo.split(':').sublist(1).join(':')
          : '',
      'host': parsed.hasPort ? '${parsed.host}:${parsed.port}' : parsed.host,
      'hostname': parsed.host,
      'port': parsed.hasPort ? '${parsed.port}' : '',
      'pathname': parsed.path.isEmpty && parsed.hasAuthority
          ? '/'
          : parsed.path,
      'search': parsed.hasQuery ? '?${parsed.query}' : '',
      'hash': parsed.hasFragment ? '#${parsed.fragment}' : '',
      'origin': parsed.hasAuthority
          ? Uri(
              scheme: parsed.scheme,
              host: parsed.host,
              port: parsed.hasPort ? parsed.port : null,
            ).toString()
          : 'null',
    };
  }
}
