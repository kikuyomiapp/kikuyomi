/// [ScriptEngine] over Kikuyomi's fork of `flutter_qjs` (ADR-0001).
///
/// This is the one place in the app that knows which JavaScript engine it runs. It lives here
/// rather than in `source_runtime` because the fork is a Flutter plugin whose native library only
/// exists inside a built application, and §2.4 keeps `source_runtime` pure Dart so that the
/// protocol, the bridges and the adapter above it can be tested with a fake engine on any machine.
/// Swapping the engine — for the Rust `rquickjs` route, or JavaScriptCore on Apple platforms —
/// means writing another file beside this one.
///
/// Because the native library is only there in a built app, the checks for this file are the probes
/// in `spikes/quickjs_binding/qjs_probe`, which run on Windows and on Android emulators in CI, not
/// `flutter test`.
library;

import 'dart:async';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';

/// Creates QuickJS runtimes. Plain data, so it can be sent to the worker isolate that will use it.
final class QuickJsScriptEngineFactory implements ScriptEngineFactory {
  const QuickJsScriptEngineFactory();

  @override
  ScriptEngine create(ScriptRuntimeLimits limits) =>
      QuickJsScriptEngine(limits: limits);
}

/// One QuickJS runtime and context, confined to the isolate that created it (§3.6).
final class QuickJsScriptEngine implements ScriptEngine {
  QuickJsScriptEngine({this.limits = const ScriptRuntimeLimits()})
    : _qjs = FlutterQjs(
        memoryLimit: limits.memoryBytes,
        stackSize: limits.stackBytes,
        // The per-entry timeout, which the fork consults only while no deadline is armed. Every
        // call here arms one, so this bounds the leftovers: a promise job the runtime runs after a
        // call has settled, and an evaluation made without a deadline.
        timeout: limits.callTimeout.inMilliseconds,
        // An extension that rejects a promise nobody awaits is its own business. Printing it would
        // be the app's only voice; the log bridge is where an extension's own messages belong.
        hostPromiseRejectionHandler: _ignoreUnhandledRejection,
      );

  static void _ignoreUnhandledRejection(dynamic reason) {}

  @override
  final ScriptRuntimeLimits limits;

  final FlutterQjs _qjs;

  /// `globalThis[name] = value`, evaluated once and kept: the only way into a runtime's globals
  /// from Dart, since the binding exposes no property setter of its own.
  JSInvokable? _setGlobal;

  /// Functions looked up by name, so that a call does not evaluate a lookup every time.
  final _functions = <String, JSInvokable>{};

  /// Drives the job queue. It runs until [dispose] closes the port; an extension's promise settles
  /// inside it.
  Future<void>? _dispatching;

  var _disposed = false;

  @override
  void defineHostFunction(String name, HostCall call) {
    _ensureOpen();
    _start();
    // The binding calls a Dart function with exactly the arguments JavaScript passed, so a script
    // that calls a host function with the wrong number of arguments would fail inside Dart's
    // Function.apply. Taking them as optionals makes that a JavaScript TypeError instead, which is
    // the extension's own mistake to see.
    _setGlobal!.invoke([
      name,
      ([Object? a, Object? b, Object? c, Object? d]) =>
          call(_arguments(a, b, c, d)),
    ]);
  }

  /// The arguments a script passed, without the trailing gaps the fixed arity leaves.
  ///
  /// `undefined` reaches Dart as null, so a script passing fewer arguments cannot be told from one
  /// passing nulls. The bridges take one object, where an absent field means the same thing, so
  /// nothing above needs the difference.
  static List<Object?> _arguments(Object? a, Object? b, Object? c, Object? d) {
    final all = [a, b, c, d];
    var last = all.length;
    while (last > 0 && all[last - 1] == null) {
      last--;
    }
    return all.sublist(0, last);
  }

  @override
  Future<Object?> evaluate(
    String code, {
    String name = '<extension>',
    Duration? deadline,
  }) {
    _ensureOpen();
    _start();
    return _guard(
      deadline ?? limits.callTimeout,
      () => _qjs.evaluate(code, name: name),
    );
  }

  @override
  Future<Object?> call(
    String name,
    List<Object?> arguments, {
    Duration? deadline,
  }) {
    _ensureOpen();
    _start();
    return _guard(deadline ?? limits.callTimeout, () {
      final function = _functions[name] ??= _lookUp(name);
      return function.invoke(arguments);
    });
  }

  JSInvokable _lookUp(String name) {
    final Object? found;
    try {
      found = _qjs.evaluate('globalThis.$name', name: '<lookup>');
    } catch (error) {
      throw ScriptEngineException('$name could not be looked up: $error');
    }
    if (found is! JSInvokable) {
      throw ScriptEngineException('$name is not a function');
    }
    return found;
  }

  @override
  void cancel() {
    if (_disposed) return;
    _qjs.cancel();
  }

  @override
  ScriptCancelHandle? get cancelHandle {
    if (_disposed) return null;
    // The runtime is built lazily, so make sure it exists before its address is taken.
    _start();
    final address = _qjs.runtimeAddress;
    return address == null ? null : QuickJsCancelHandle(address);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final function in _functions.values) {
      function.free();
    }
    _functions.clear();
    _setGlobal?.free();
    _setGlobal = null;
    _qjs.close();
    // Ends the dispatch loop. Closing before close() would leave the last jobs undriven.
    _qjs.port.close();
    await _dispatching;
    _dispatching = null;
  }

  void _ensureOpen() {
    if (_disposed) {
      throw const ScriptEngineException('the runtime has been disposed');
    }
  }

  /// Creates the runtime, the job loop and the global setter, once.
  void _start() {
    if (_setGlobal != null) return;
    _dispatching = _qjs.dispatch();
    final setter = _qjs.evaluate(
      '(k, v) => { globalThis[k] = v; }',
      name: '<host>',
    );
    if (setter is! JSInvokable) {
      throw const ScriptEngineException('the runtime refused a global setter');
    }
    _setGlobal = setter;
  }

  /// Runs [body] under a deadline, and turns however it fails into a [ScriptException].
  ///
  /// The deadline is armed in the engine, where it stops a script that is running. It is applied a
  /// second time here, on the future, because a script that is *not* running cannot be interrupted:
  /// an extension awaiting a host promise that never settles would otherwise leave this future
  /// pending for ever. Both paths end with the runtime idle and usable.
  Future<Object?> _guard(Duration deadline, Object? Function() body) async {
    final started = Stopwatch()..start();
    _qjs.armDeadline(deadline);
    try {
      final result = body();
      if (result is! Future) return _plain(result);
      final left = deadline - started.elapsed;
      return await result
          .timeout(
            left.isNegative ? Duration.zero : left,
            onTimeout: () {
              // The script is idle, or blocked on something outside the engine. Ask it to stop, so that
              // it does not carry on when the job queue next runs.
              _qjs.cancel();
              throw ScriptDeadlineException(
                deadline,
                'the call did not settle',
              );
            },
          )
          .then(_plain);
    } on ScriptException {
      rethrow;
    } catch (error) {
      throw _failure(error, deadline);
    } finally {
      if (!_disposed) _qjs.disarmDeadline();
    }
  }

  /// [value] with every JavaScript handle in it released and replaced by null.
  ///
  /// Only plain data crosses this interface, and the binding hands back a live reference for
  /// anything else: a function, or an object it could not read. Such a reference belongs to the
  /// runtime, so leaving it to a caller that has no way to free it makes closing the runtime report
  /// a leaked reference — which is how this was found. A script whose last statement is
  /// `globalThis.f = function () {}` returns one without meaning to, so this is the common case
  /// rather than the odd one.
  Object? _plain(Object? value, [Map<Object, Object?>? seen]) {
    if (value is JSRef) {
      value.free();
      return null;
    }
    if (value is List) {
      final visited = seen ?? Map<Object, Object?>.identity();
      if (visited.containsKey(value)) return visited[value];
      final copy = <Object?>[];
      visited[value] = copy;
      for (final element in value) {
        copy.add(_plain(element, visited));
      }
      return copy;
    }
    if (value is Map) {
      final visited = seen ?? Map<Object, Object?>.identity();
      if (visited.containsKey(value)) return visited[value];
      final copy = <Object?, Object?>{};
      visited[value] = copy;
      for (final entry in value.entries) {
        copy[_plain(entry.key, visited)] = _plain(entry.value, visited);
      }
      return copy;
    }
    return value;
  }

  /// What [error] means, told apart by the reason the fork recorded for the last interrupt.
  ///
  /// QuickJS reports a deadline, a cancellation and a script's own `throw new InternalError` with
  /// the same text, so the reason is read from the runtime rather than from the message.
  ScriptException _failure(Object error, Duration deadline) {
    final text = '$error'.split('\n').first.trim();
    final reason = _disposed
        ? JSInterruptReason.NONE
        : _qjs.takeInterruptReason();
    switch (reason) {
      case JSInterruptReason.DEADLINE:
      case JSInterruptReason.TIMEOUT:
        return ScriptDeadlineException(deadline, text);
      case JSInterruptReason.CANCEL:
        return ScriptCancelledException(text);
    }
    if (text.contains('out of memory')) {
      return ScriptMemoryException(limits.memoryBytes, text);
    }
    // An interrupt with no reason recorded: the runtime was interrupted before the fork's reason
    // was read, or a script threw this text itself. Treating it as the deadline is the safe way
    // round, because a call that was stopped must not look like a result.
    if (text.contains('interrupted')) {
      return ScriptDeadlineException(deadline, text);
    }
    return ScriptThrewException(text);
  }
}

/// Stops a QuickJS runtime's call from another isolate.
///
/// Plain data: the runtime's address, which every isolate of the group can reach, and which the
/// fork's cancellation flag is atomic for. It is valid only while the engine is alive, so the
/// holder must drop it when the call it belongs to has finished.
final class QuickJsCancelHandle implements ScriptCancelHandle {
  const QuickJsCancelHandle(this.runtimeAddress);

  final int runtimeAddress;

  @override
  void cancel() => FlutterQjs.cancelRuntimeAt(runtimeAddress);
}
