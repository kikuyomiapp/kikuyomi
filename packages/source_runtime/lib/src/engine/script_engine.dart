/// The JavaScript engine, behind the one interface ADR-0001 keeps as its escape hatch.
///
/// ADR-0001 chose a vendored fork of `flutter_qjs` and recorded that "the escape hatch is
/// `ScriptEngine`": the engine sits behind this interface so that switching to the Rust `rquickjs`
/// route, or to JavaScriptCore on Apple platforms if App Store review ever demanded it, means
/// implementing one interface rather than touching the extension system.
///
/// Nothing here mentions QuickJS, and nothing here is a Flutter plugin: the implementation over the
/// fork lives in `platform_adapters`, because the fork is a plugin and this package stays pure Dart
/// so that everything above the engine can be tested with a fake one, on any machine, in seconds.
///
/// **Only plain data crosses** an engine's boundary, in both directions: `null`, `bool`, `int`,
/// `double`, `String`, `Uint8List` for bytes, `List` and `Map` of those. That is the same rule the
/// contract puts on extensions (SourceAPI 1.0, "Ground rules"), and holding the engine to it too is
/// what lets a runtime live in a worker isolate (§3.6) and what keeps an engine's own types out of
/// the rest of the app.
library;

import 'dart:async';

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

/// A function the host exposes to JavaScript, as [ScriptEngine.defineHostFunction] installs it.
///
/// [arguments] are the arguments the script passed, as plain data. What it returns is handed back
/// to the script, as plain data; a `Future` arrives in JavaScript as a promise, which is how the
/// asynchronous bridges of §3.5 work. Throwing turns into a JavaScript exception the script can
/// catch.
typedef HostCall = FutureOr<Object?> Function(List<Object?> arguments);

/// The limits one runtime is created with (§3.6).
///
/// The defaults are SourceAPI 1.0's Limits table, read from `source_api` so that no figure in the
/// contract is written down twice.
final class ScriptRuntimeLimits {
  const ScriptRuntimeLimits({
    this.memoryBytes = SourceLimits.maxRuntimeMemoryBytes,
    this.stackBytes = defaultStackBytes,
    this.callTimeout = SourceLimits.callTimeout,
  });

  /// The stack one runtime may use. QuickJS's own default is 256 KB; extensions are scrapers, not
  /// deeply recursive programs, and a stack limit turns runaway recursion into an error rather
  /// than a native crash that would take the app with it.
  static const defaultStackBytes = 512 * 1024;

  /// The most memory this runtime may allocate, in bytes. Passing it fails the call with
  /// [ScriptMemoryException] rather than exhausting the device.
  final int memoryBytes;

  /// The most stack this runtime may use, in bytes.
  final int stackBytes;

  /// How long one call may run before the watchdog stops it, when a call does not say otherwise.
  final Duration callTimeout;
}

/// One JavaScript runtime: an extension's own world, created for it and thrown away with it.
///
/// One runtime per extension, not per source (§3.6). A runtime is confined to the isolate that
/// created it: every method must be called from there, [cancel] and [cancelHandle] excepted.
///
/// **The deadline is armed for one call.** Each call takes a deadline and the runtime is bounded by
/// it from the moment the call starts until it settles, however many times the script crosses into
/// the host and back. ADR-0001 records why that has to be said out loud: the binding used to
/// restart its timeout on every entry from Dart into JavaScript, so a script looping over a host
/// call was never stopped.
abstract interface class ScriptEngine {
  /// The limits this runtime was created with.
  ScriptRuntimeLimits get limits;

  /// Installs [call] as a global function named [name], for the prelude's bridge shims to reach.
  ///
  /// Called before any extension code is evaluated. A name the extension can guess is not a
  /// weakness: the bridges are the only thing a script can reach anyway, and every one of them
  /// validates what it is given.
  void defineHostFunction(String name, HostCall call);

  /// Evaluates [code] in this runtime, as a script rather than a module.
  ///
  /// [name] appears in a script's stack traces. The result is the value of the last expression, as
  /// plain data, awaited when it is a promise.
  Future<Object?> evaluate(String code, {String name, Duration? deadline});

  /// Calls the global function [name] with [arguments], and settles its promise.
  ///
  /// [name] may be a dotted path to a function on a global object. The job queue is driven until
  /// the returned promise settles, so an extension method that awaits a host bridge completes here
  /// rather than being left pending.
  Future<Object?> call(
    String name,
    List<Object?> arguments, {
    Duration? deadline,
  });

  /// Asks for whatever is running to stop, from this isolate.
  ///
  /// Useful from a host function the script itself called. While a script runs without calling
  /// back, this isolate is inside the engine and reaches none of its own messages; [cancelHandle]
  /// is how another isolate stops such a script.
  void cancel();

  /// A token another isolate can stop this runtime's running call with, or null when this engine
  /// cannot be stopped from outside.
  ///
  /// It is plain data and safe to send to another isolate. It is only valid while this engine is
  /// alive: using it after [dispose] does nothing at best.
  ScriptCancelHandle? get cancelHandle;

  /// Frees the runtime. Every later call fails with [ScriptEngineException].
  Future<void> dispose();
}

/// Creates runtimes. Sendable to a worker isolate, which is where runtimes live (§3.6).
///
/// The app composes the real one; tests pass a fake. An implementation holds nothing but plain
/// data, so that it survives being sent to the isolate that will use it.
abstract interface class ScriptEngineFactory {
  /// A new runtime, held to [limits].
  ScriptEngine create(ScriptRuntimeLimits limits);
}

/// Stops a call from outside the isolate running it.
///
/// Implementations hold plain data only, because this crosses to another isolate. Cancelling a call
/// that has already finished does nothing.
abstract interface class ScriptCancelHandle {
  void cancel();
}

/// Why a call into a runtime failed.
///
/// The adapter turns each of these into the contract's error kinds; they are kept apart here
/// because §3.6 marks an extension unhealthy for tripping the watchdog, which is not the same
/// judgement as a source whose page could not be read.
sealed class ScriptException implements Exception {
  const ScriptException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The script threw.
///
/// [thrown] is what it threw, as plain data, when the engine could read it: an object with a `kind`
/// for one of the SDK's errors, or whatever else the script threw. It is null when the engine could
/// only describe the throw, which is what happens for a syntax error or an error the engine itself
/// raised.
final class ScriptThrewException extends ScriptException {
  const ScriptThrewException(super.message, {this.thrown});

  final Object? thrown;
}

/// The call ran past its deadline and was stopped (§3.6's watchdog).
final class ScriptDeadlineException extends ScriptException {
  const ScriptDeadlineException(this.deadline, [String message = ''])
    : super(message);

  final Duration deadline;

  @override
  String toString() =>
      'ScriptDeadlineException: the call ran longer than ${deadline.inSeconds} s'
      '${message.isEmpty ? '' : ' ($message)'}';
}

/// The runtime asked for more memory than its limit allows.
///
/// The runtime is usable afterwards: what it had allocated is freed as the call unwinds, and the
/// next call starts from the memory the runtime already held.
final class ScriptMemoryException extends ScriptException {
  const ScriptMemoryException(this.limitBytes, [String message = ''])
    : super(message);

  final int limitBytes;

  @override
  String toString() =>
      'ScriptMemoryException: the extension asked for more than '
      '${limitBytes ~/ (1024 * 1024)} MB'
      '${message.isEmpty ? '' : ' ($message)'}';
}

/// The host stopped the call: the listener navigated away, or the extension is being unloaded.
final class ScriptCancelledException extends ScriptException {
  const ScriptCancelledException([super.message = '']);
}

/// The engine itself failed, or was used after it was disposed. Not the extension's doing.
final class ScriptEngineException extends ScriptException {
  const ScriptEngineException(super.message);
}
