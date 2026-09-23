// A script engine with no script in it.
//
// The engine behind `ScriptEngine` is a Flutter plugin whose native library only exists inside a
// built application, so everything above the engine is tested against this instead: a fake that
// answers the protocol's calls the way the prelude does, including its `{ ok, value }` and
// `{ ok, error }` shapes and the plain data an error becomes. What the real engine and the real
// prelude do together is checked by the probes in spikes/quickjs_binding, on Windows and on Android
// emulators.

import 'dart:async';

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';

/// One source of a fake extension: what each of its methods answers.
typedef FakeMethod = FutureOr<Object?> Function(List<Object?> arguments);

/// An extension written in Dart, standing in for one written in JavaScript.
final class FakeExtension {
  const FakeExtension(this.sources);

  final Map<String, Map<String, FakeMethod>> sources;
}

/// One call the engine was asked to make.
final class RecordedCall {
  const RecordedCall(this.function, this.arguments, this.deadline);

  final String function;
  final List<Object?> arguments;
  final Duration? deadline;

  /// The source key, method and arguments of a call into an extension.
  (String, String, List<Object?>) get invocation => (
    arguments[0]! as String,
    arguments[1]! as String,
    arguments[2]! as List<Object?>,
  );
}

/// A [ScriptEngine] that runs a [FakeExtension] instead of JavaScript.
///
/// It answers the three functions the prelude installs, and nothing else, so a test exercises the
/// same protocol the real runtime uses.
final class FakeScriptEngine implements ScriptEngine {
  FakeScriptEngine({
    this.extension = const FakeExtension({}),
    this.limits = const ScriptRuntimeLimits(),
  });

  final FakeExtension extension;

  @override
  final ScriptRuntimeLimits limits;

  /// Everything evaluated, in order: the host's facts, the prelude, the wrapped bundle.
  final evaluated = <String>[];

  /// The host functions the runtime installed, by name.
  final hostFunctions = <String, HostCall>{};

  /// Every call made into the runtime.
  final calls = <RecordedCall>[];

  /// Set to fail the next call with this, instead of answering it: the watchdog, the memory limit,
  /// or a cancellation.
  ScriptException? failNextCall;

  /// Set to fail the next evaluation, for an extension whose code does not run.
  ScriptException? failNextEvaluate;

  /// Set to answer `__kikuyomiRuntime.invoke` with this, whatever the extension would have said:
  /// an extension, or a prelude, that does not keep to the protocol.
  Object? Function()? answerInvokeWith;

  var disposed = false;
  var cancelled = 0;

  @override
  void defineHostFunction(String name, HostCall call) {
    hostFunctions[name] = call;
  }

  @override
  Future<Object?> evaluate(
    String code, {
    String name = '<extension>',
    Duration? deadline,
  }) async {
    final failure = failNextEvaluate;
    if (failure != null) {
      failNextEvaluate = null;
      throw failure;
    }
    evaluated.add(code);
    return null;
  }

  @override
  Future<Object?> call(
    String name,
    List<Object?> arguments, {
    Duration? deadline,
  }) async {
    calls.add(RecordedCall(name, arguments, deadline));
    final failure = failNextCall;
    if (failure != null) {
      failNextCall = null;
      throw failure;
    }
    switch (name) {
      case '__kikuyomiRuntime.sourceKeys':
        return extension.sources.keys.toList();
      case '__kikuyomiRuntime.hasMethod':
        final source = extension.sources[arguments[0]];
        return source != null && source.containsKey(arguments[1]);
      case '__kikuyomiRuntime.invoke':
        final answer = answerInvokeWith;
        if (answer != null) return answer();
        return _invoke(arguments);
      default:
        throw ScriptEngineException('$name is not a function');
    }
  }

  /// What the prelude's `invoke` does: await the method, and turn a throw into plain data rather
  /// than letting it cross as an exception.
  Future<Object?> _invoke(List<Object?> arguments) async {
    final sourceKey = arguments[0];
    final method = arguments[1];
    final args = (arguments[2] as List<Object?>?) ?? const [];
    try {
      final source = extension.sources[sourceKey];
      if (source == null) {
        throw Exception('the extension has no source "$sourceKey"');
      }
      final function = source[method];
      if (function == null) {
        throw Exception('the source "$sourceKey" has no $method()');
      }
      return {'ok': true, 'value': await function(args)};
    } catch (error) {
      return {'ok': false, 'error': describeThrow(error)};
    }
  }

  @override
  void cancel() => cancelled++;

  @override
  ScriptCancelHandle? get cancelHandle => null;

  @override
  Future<void> dispose() async => disposed = true;
}

/// What the prelude makes of a thrown value: plain data with the fields the contract's kinds have.
///
/// A [SourceException] thrown by a fake method stands in for the SDK's error classes, which are
/// what an extension throws.
Object? describeThrow(Object? thrown) => switch (thrown) {
  ChallengeRequiredException(:final url, :final message) => {
    'kind': 'ChallengeRequired',
    'url': url.toString(),
    'message': message,
  },
  RateLimitedException(:final retryAfterMs, :final message) => {
    'kind': 'RateLimited',
    if (retryAfterMs != null) 'retryAfterMs': retryAfterMs,
    'message': message,
  },
  final SourceException error => {'kind': error.kind, 'message': error.message},
  final String text => text,
  _ => {'name': 'Error', 'message': '$thrown'},
};

/// The domains of the extension under test.
final testDomains = DomainAllowlist(['example.org', '*.cdn.example.org']);

/// A bundle whose code is never read, because the fake engine does not run it.
ExtensionBundle testBundle({String code = 'module.exports = {};'}) =>
    ExtensionBundle(
      extensionId: 'org.example.test',
      code: code,
      domains: testDomains,
    );

/// The host facts a test runtime is loaded with.
const testHost = HostFacts(appVersion: '1.2.3', features: {'ui.browser'});

/// Loads [extension] into a fake engine, ready to call.
Future<(ExtensionRuntime, FakeScriptEngine)> loadFake(
  FakeExtension extension, {
  Iterable<HostBridge> bridges = const [],
}) async {
  final engine = FakeScriptEngine(extension: extension);
  final runtime = await ExtensionRuntime.load(
    engine: engine,
    bundle: testBundle(),
    host: testHost,
    bridges: bridges,
  );
  return (runtime, engine);
}

/// A factory of plain data, for the worker isolate, which only values may cross to.
///
/// The engine it makes answers a fixed script rather than running one: a fake built from closures
/// could not be sent, which is the very constraint [ScriptEngineFactory] exists to state.
final class ScriptedEngineFactory implements ScriptEngineFactory {
  const ScriptedEngineFactory();

  @override
  ScriptEngine create(ScriptRuntimeLimits limits) => ScriptedEngine(limits);
}

/// An engine that answers the protocol from a script written here.
///
/// `echo` gives back what it was called with, `getPopular` answers one page of the contract's own
/// shape, `rateLimited` and `challenge` fail with those kinds, `slow` is stopped by the watchdog,
/// and `fetch` calls the host function the runtime installed, which is how a test sees a bridge
/// crossing back out of the worker.
final class ScriptedEngine implements ScriptEngine {
  ScriptedEngine(this.limits);

  @override
  final ScriptRuntimeLimits limits;

  static const methods = {
    'echo',
    'getPopular',
    'rateLimited',
    'challenge',
    'slow',
    'fetch',
  };

  final _hostFunctions = <String, HostCall>{};

  @override
  void defineHostFunction(String name, HostCall call) =>
      _hostFunctions[name] = call;

  @override
  Future<Object?> evaluate(
    String code, {
    String name = '<extension>',
    Duration? deadline,
  }) async {
    if (code.contains('refuse to load')) {
      throw const ScriptThrewException('SyntaxError: unexpected identifier');
    }
    return null;
  }

  @override
  Future<Object?> call(
    String name,
    List<Object?> arguments, {
    Duration? deadline,
  }) async {
    switch (name) {
      case '__kikuyomiRuntime.sourceKeys':
        return ['scripted'];
      case '__kikuyomiRuntime.hasMethod':
        return methods.contains(arguments[1]);
      case '__kikuyomiRuntime.invoke':
        final method = arguments[1];
        final args = (arguments[2] as List<Object?>?) ?? const [];
        switch (method) {
          case 'echo':
            return {
              'ok': true,
              'value': {'method': method, 'arguments': args},
            };
          case 'getPopular':
            return {
              'ok': true,
              'value': {
                'items': [
                  {
                    'key': 'b${args.isEmpty ? 0 : args.first}',
                    'title': 'Typee',
                    'coverUrl': 'https://example.org/typee.jpg',
                  },
                ],
                'hasNextPage': false,
              },
            };
          case 'rateLimited':
            return {
              'ok': false,
              'error': {
                'kind': 'RateLimited',
                'message': 'slow down',
                'retryAfterMs': 1500,
              },
            };
          case 'challenge':
            return {
              'ok': false,
              'error': {
                'kind': 'ChallengeRequired',
                'url': 'https://example.org/check',
              },
            };
          case 'slow':
            throw const ScriptDeadlineException(Duration(seconds: 30));
          case 'fetch':
            try {
              final answer = await _hostFunctions[HostApi.entryPoint]!([
                'http',
                'fetch',
                args,
              ]);
              return {'ok': true, 'value': answer};
            } catch (error) {
              return {
                'ok': false,
                'error': {'kind': 'Parse', 'message': '$error'},
              };
            }
          default:
            return {
              'ok': false,
              'error': {
                'kind': 'Parse',
                'message': 'the source "scripted" has no $method()',
              },
            };
        }
      default:
        throw ScriptEngineException('$name is not a function');
    }
  }

  @override
  void cancel() {}

  @override
  ScriptCancelHandle? get cancelHandle => null;

  @override
  Future<void> dispose() async {}
}
