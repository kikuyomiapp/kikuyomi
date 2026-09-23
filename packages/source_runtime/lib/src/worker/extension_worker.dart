/// One extension's runtime, in a worker isolate of its own (§3.6).
///
/// "Extension execution runs in a small pool of worker isolates. Each worker hosts several QuickJS
/// runtimes, one per extension, and HTML parsing happens in the same worker, so CPU-heavy parsing
/// never touches the UI thread." (§2.7) A runtime is confined to the isolate that created it, so
/// everything about it — the engine, the parsed documents, the deadline — lives there, and only
/// plain data crosses.
///
/// **Where the pool goes.** This is one worker per extension, which is the simple case and the one
/// the first extension needs. Pooling and eviction — "twelve warm runtimes across the pool, evicted
/// after five idle minutes or when the OS signals memory pressure" — are a later step, and they go
/// in front of this class rather than inside it: an `ExtensionWorkerPool` that keeps a map of
/// extension id to [ExtensionWorker], starts one on first use, and disposes the least recently used
/// when it has too many. Nothing here would change, because the worker already owns exactly one
/// extension's runtime and already tears it down on [dispose].
///
/// **Which bridges live where.** `html` and `crypto` run inside the worker, because they are the
/// CPU work §2.7 moved off the UI thread and because the contract makes `html`'s element methods
/// synchronous, which no message crossing could be. `http`, `storage` and `log` are proxied to the
/// isolate that started the worker: §2.7 gives the whole app one `NetworkService` that owns the
/// cookie jars and the rate limiters, and storage and the console belong to the app as well.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

import '../bridges/crypto_bridge.dart';
import '../bridges/host_bridge.dart';
import '../bridges/html_bridge.dart';
import '../engine/script_engine.dart';
import '../extension/extension_runtime.dart';
import '../extension/js_source_adapter.dart';

/// The modules a worker forwards to the isolate that started it, in the order they are looked up.
const proxiedHostModules = ['http', 'storage', 'log'];

/// One extension, running in an isolate of its own.
///
/// It is an [ExtensionCalls], so `JsSourceAdapter` sits over a worker exactly as it sits over an
/// [ExtensionRuntime] called in this isolate: the app gets the confined runtime §3.6 asks for, and
/// the contract is enforced by the same decoder either way.
final class ExtensionWorker implements ExtensionCalls {
  ExtensionWorker._(
    this._isolate,
    this._toWorker,
    this._fromWorker,
    this._id,
    DomainAllowlist domains,
    this._bridges,
  ) : _decoder = PlainDataDecoder(domains);

  /// Starts a worker, loads [bundle] in it, and waits until the extension is ready to be called.
  ///
  /// [engineFactory] and [bundle] cross to the isolate, so both must hold plain data only, which is
  /// why [ScriptEngineFactory] is specified that way. [bridges] stay here: the worker forwards
  /// [proxiedHostModules] to them.
  ///
  /// Throws [ExtensionLoadException] when the extension does not load.
  static Future<ExtensionWorker> start({
    required ScriptEngineFactory engineFactory,
    required ExtensionBundle bundle,
    required HostFacts host,
    required Iterable<HostBridge> bridges,
    ScriptRuntimeLimits limits = const ScriptRuntimeLimits(),
  }) async {
    final fromWorker = ReceivePort();
    // One subscription for the whole life of the worker. The first message is its answer to
    // starting; everything after it belongs to the worker, and anything that arrives before the
    // worker exists is kept until it does.
    final ready = Completer<Object?>();
    final waitingForTheWorker = <Object?>[];
    ExtensionWorker? worker;
    fromWorker.listen((message) {
      if (!ready.isCompleted) {
        ready.complete(message);
        return;
      }
      final started = worker;
      if (started == null) {
        waitingForTheWorker.add(message);
      } else {
        started._handle(message);
      }
    });
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        _WorkerStart(
          reply: fromWorker.sendPort,
          engineFactory: engineFactory,
          bundle: bundle,
          host: host,
          limits: limits,
        ),
        debugName: 'kikuyomi:${bundle.extensionId}',
        errorsAreFatal: true,
        // An isolate that dies takes its answers with it, and without these the caller would wait
        // for one that is never coming. An error arrives as a two-element list, and the end as
        // null.
        onError: fromWorker.sendPort,
        onExit: fromWorker.sendPort,
      );
    } catch (error) {
      fromWorker.close();
      throw ExtensionLoadException(bundle.extensionId, '$error');
    }
    final answer = await ready.future;
    if (answer is! _WorkerReady) {
      isolate.kill(priority: Isolate.immediate);
      fromWorker.close();
      throw ExtensionLoadException(bundle.extensionId, switch (answer) {
        _WorkerFailed(:final message) => message,
        final List<Object?> failure when failure.isNotEmpty =>
          '${failure.first}',
        _ => 'the worker stopped before it was ready',
      });
    }
    final started = ExtensionWorker._(
      isolate,
      answer.toWorker,
      fromWorker,
      bundle.extensionId,
      bundle.domains,
      {for (final bridge in bridges) bridge.module: bridge},
    ).._sourceKeys = answer.sourceKeys;
    worker = started;
    for (final message in waitingForTheWorker) {
      started._handle(message);
    }
    waitingForTheWorker.clear();
    return started;
  }

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  final String _id;
  final PlainDataDecoder _decoder;

  /// The modules this isolate answers for the worker: [proxiedHostModules].
  final Map<String, HostBridge> _bridges;

  final _waiting = <int, Completer<Object?>>{};
  var _nextCall = 1;
  List<String> _sourceKeys = const [];
  var _disposed = false;

  /// The extension in this worker.
  @override
  String get extensionId => _id;

  /// The decoder every result of this extension is read with, built from its own domains.
  @override
  PlainDataDecoder get decoder => _decoder;

  /// The source keys it exports.
  List<String> get sourceKeys => _sourceKeys;

  /// Whether a source has an optional method.
  @override
  Future<bool> hasMethod(String sourceKey, String method) async =>
      await _send(_HasMethod(sourceKey, method)) == true;

  /// Calls one of the extension's methods and gives back its result as plain data.
  ///
  /// Throws a [SourceException], as [ExtensionRuntime.invoke] does: the kind crosses as data and is
  /// read back on this side, because an exception is not something to send between isolates.
  Future<Object?> invoke(
    String sourceKey,
    String method,
    List<Object?> arguments, {
    Duration? deadline,
  }) => _send(_Invoke(sourceKey, method, arguments, deadline?.inMilliseconds));

  Future<Object?> _send(Object message) {
    if (_disposed) {
      throw const ParseException('the extension has been unloaded');
    }
    final id = _nextCall++;
    final answer = Completer<Object?>();
    _waiting[id] = answer;
    _toWorker.send(_Envelope(id, message));
    return answer.future;
  }

  /// One message from the worker.
  void _handle(Object? message) {
    switch (message) {
      case _Answer(:final id, :final value):
        _waiting.remove(id)?.complete(value);
      case _Failed(:final id, :final error):
        _waiting.remove(id)?.completeError(_decoder.decodeError(error));
      case _HostCall(:final id, :final module, :final method, :final args):
        unawaited(_answerHostCall(id, module, method, args, _bridges));
      case _WorkerFailed(:final message):
        _failEverything(ParseException(message));
      // What `onError` sends: the error and its stack, as text.
      case final List<Object?> failure when failure.length == 2:
        _failEverything(
          ParseException('the extension runtime failed: ${failure.first}'),
        );
      // What `onExit` sends. Anything still waiting will never be answered.
      case null:
        _failEverything(const ParseException('the extension runtime stopped'));
    }
  }

  Future<void> _answerHostCall(
    int id,
    String module,
    String method,
    List<Object?> arguments,
    Map<String, HostBridge> bridges,
  ) async {
    try {
      final bridge = bridges[module];
      if (bridge == null) {
        throw HostCallException('there is no host module "$module"');
      }
      _toWorker.send(
        _Envelope(id, _Answer(id, await bridge.call(method, arguments))),
      );
    } catch (error) {
      _toWorker.send(
        _Envelope(id, _Failed(id, {'message': '$error', 'name': 'Error'})),
      );
    }
  }

  void _failEverything(SourceException failure) {
    for (final waiting in _waiting.values) {
      if (!waiting.isCompleted) waiting.completeError(failure);
    }
    _waiting.clear();
  }

  /// Stops the worker and frees the runtime inside it.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _toWorker.send(const _Envelope(0, _Dispose()));
    // The worker frees its runtime and exits; this bounds how long that may take, because a
    // runtime that is stuck inside a script would otherwise keep the isolate alive.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _fromWorker.close();
    _failEverything(const ParseException('the extension has been unloaded'));
  }
}

// ------------------------------------------------------------------------------------------------
// What crosses between the two isolates. Every message holds plain data, an engine factory or a
// bundle, all of which are values: no closures, no ports but the two the worker is given.

final class _WorkerStart {
  const _WorkerStart({
    required this.reply,
    required this.engineFactory,
    required this.bundle,
    required this.host,
    required this.limits,
  });

  final SendPort reply;
  final ScriptEngineFactory engineFactory;
  final ExtensionBundle bundle;
  final HostFacts host;
  final ScriptRuntimeLimits limits;
}

final class _WorkerReady {
  const _WorkerReady(this.toWorker, this.sourceKeys);

  final SendPort toWorker;
  final List<String> sourceKeys;
}

final class _WorkerFailed {
  const _WorkerFailed(this.message);

  final String message;
}

final class _Envelope {
  const _Envelope(this.id, this.message);

  final int id;
  final Object message;
}

final class _Invoke {
  const _Invoke(this.sourceKey, this.method, this.arguments, this.deadlineMs);

  final String sourceKey;
  final String method;
  final List<Object?> arguments;
  final int? deadlineMs;
}

final class _HasMethod {
  const _HasMethod(this.sourceKey, this.method);

  final String sourceKey;
  final String method;
}

final class _Dispose {
  const _Dispose();
}

final class _Answer {
  const _Answer(this.id, this.value);

  final int id;
  final Object? value;
}

final class _Failed {
  const _Failed(this.id, this.error);

  final int id;

  /// The error as plain data, in the shape SourceAPI 1.0 gives a thrown error, so that the kind is
  /// read back on the other side by the same decoder that reads an extension's own throw.
  final Object? error;
}

final class _HostCall {
  const _HostCall(this.id, this.module, this.method, this.args);

  final int id;
  final String module;
  final String method;
  final List<Object?> args;
}

/// The worker isolate's whole life.
Future<void> _workerMain(_WorkerStart start) async {
  final toWorker = ReceivePort();
  final proxies = <String, _ProxyBridge>{
    for (final module in proxiedHostModules)
      module: _ProxyBridge(module, start.reply),
  };
  final ExtensionRuntime runtime;
  try {
    runtime = await ExtensionRuntime.load(
      engine: start.engineFactory.create(start.limits),
      bundle: start.bundle,
      host: start.host,
      bridges: [HtmlBridge(), const CryptoBridge(), ...proxies.values],
    );
  } catch (error) {
    start.reply.send(_WorkerFailed('$error'));
    toWorker.close();
    return;
  }
  start.reply.send(_WorkerReady(toWorker.sendPort, runtime.sourceKeys));

  await for (final message in toWorker) {
    if (message is! _Envelope) continue;
    switch (message.message) {
      case _Dispose():
        await runtime.dispose();
        toWorker.close();
      case _Invoke(
        :final sourceKey,
        :final method,
        :final arguments,
        :final deadlineMs,
      ):
        unawaited(() async {
          try {
            final value = await runtime.invoke(
              sourceKey,
              method,
              arguments,
              deadline: deadlineMs == null
                  ? null
                  : Duration(milliseconds: deadlineMs),
            );
            start.reply.send(_Answer(message.id, value));
          } on SourceException catch (error) {
            start.reply.send(_Failed(message.id, _asPlainData(error)));
          } catch (error) {
            start.reply.send(
              _Failed(message.id, {'kind': 'Parse', 'message': '$error'}),
            );
          }
        }());
      case _HasMethod(:final sourceKey, :final method):
        unawaited(() async {
          try {
            start.reply.send(
              _Answer(message.id, await runtime.hasMethod(sourceKey, method)),
            );
          } catch (error) {
            start.reply.send(
              _Failed(message.id, {'kind': 'Parse', 'message': '$error'}),
            );
          }
        }());
      // An answer to something this worker asked the other side for.
      case _Answer(:final id, :final value):
        proxies.values
            .map((proxy) => proxy.waiting.remove(id))
            .whereType<Completer<Object?>>()
            .forEach((waiting) => waiting.complete(value));
      case _Failed(:final id, :final error):
        proxies.values
            .map((proxy) => proxy.waiting.remove(id))
            .whereType<Completer<Object?>>()
            .forEach(
              (waiting) => waiting.completeError(
                HostCallException(
                  error is Map ? '${error['message']}' : '$error',
                ),
              ),
            );
    }
  }
}

/// The error an extension threw, as the plain data the contract describes it with.
///
/// It crosses as data rather than as an exception so that nothing about it depends on what an
/// isolate message may hold.
Map<String, Object?> _asPlainData(SourceException error) => switch (error) {
  ChallengeRequiredException(:final url) => {
    'kind': error.kind,
    'message': error.message,
    'url': url.toString(),
  },
  RateLimitedException(:final retryAfterMs) => {
    'kind': error.kind,
    'message': error.message,
    if (retryAfterMs != null) 'retryAfterMs': retryAfterMs,
  },
  _ => {'kind': error.kind, 'message': error.message},
};

/// A module that lives in the isolate that started the worker.
final class _ProxyBridge implements HostBridge {
  _ProxyBridge(this.module, this._reply);

  @override
  final String module;

  final SendPort _reply;

  /// The calls this worker is waiting for an answer to, by id. The ids come from the same counter
  /// as everything else the worker sends, so an answer can never be mistaken for another's.
  final waiting = <int, Completer<Object?>>{};

  static var _nextId = 1000000;

  @override
  Future<Object?> call(String method, List<Object?> arguments) {
    final id = _nextId++;
    final answer = Completer<Object?>();
    waiting[id] = answer;
    _reply.send(_HostCall(id, module, method, arguments));
    return answer.future;
  }
}
