// Spike (a) probe. Throwaway.
//
// Answers two questions about Kikuyomi's fork of flutter_qjs 0.3.7 (third_party/flutter_qjs):
//
//  1. Does it build and run, and do the interrupt handler and memory limit that ffi.cpp exposes
//     actually work from Dart? Probes 1 to 6, unchanged in meaning since the Windows run.
//  2. What does the interrupt deadline measure? Upstream's ffi.cpp timed it with clock(), which is
//     wall time in the Windows CRT and process CPU time on POSIX, Android included. Probes 7 to
//     10. Probes 11 and 12 then check what the host is told when the memory limit leaves no room
//     for an error object, which probe 5 met by chance on API 26, synchronously and in an async
//     function.
//  3. Does Kikuyomi's own `ScriptEngine` work on a device? Probes 13 to 19 drive
//     `QuickJsScriptEngine` (packages/platform_adapters) through the interface in
//     packages/source_runtime: load a small extension, call a method, take a typed error, and meet
//     the deadline, the memory limit and a cancellation. These cannot run under `flutter test`,
//     because a plugin's native library is not built there, so they run here. Probe 14 is the one
//     the fork's per-call deadline was written for.
//  4. Does the extension protocol run? Probes 20 to 22 load a small extension through
//     `ExtensionRuntime`, with the real prelude and the real bridges, and call it through
//     `JsSourceAdapter`. The prelude is JavaScript, and only QuickJS can say whether it runs.
//
// This is a console probe wearing a Flutter app as a costume, because the plugin's native library
// is only present in a built Flutter application. It runs every probe at start, unattended, and
// writes one line per event:
//
//   QJS_PROBE INFO <key>=<value>
//   QJS_PROBE START <probe>
//   QJS_PROBE PASS <probe> <details>
//   QJS_PROBE FAIL <probe> <details>
//   QJS_PROBE DONE passed=<n> failed=<m>
//
// On Android the lines go through print(), which Flutter forwards to logcat under the tag
// "flutter"; stdout goes nowhere there. On desktop they go to stdout and the process exits with
// the failure count as its status. A START without its PASS or FAIL means the probe hung.
//
// Probes 7 to 10 are measurements. They pass when the measurement is unambiguous and state what it
// found as `verdict=...`; they fail only when the numbers fit no explanation.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';

int _passed = 0;
int _failed = 0;
final List<String> _lines = [];

void _emit(String line) {
  _lines.add(line);
  if (Platform.isAndroid) {
    // ignore: avoid_print
    print(line);
  } else {
    stdout.writeln(line);
  }
}

String _oneLine(Object? text, [int max = 160]) {
  final flat = '$text'.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > max ? '${flat.substring(0, max)}...' : flat;
}

void _report(String name, bool ok, String detail) {
  ok ? _passed++ : _failed++;
  _emit('QJS_PROBE ${ok ? 'PASS' : 'FAIL'} $name ${_oneLine(detail, 400)}');
}

/// Runs one probe. The body returns its details on success and throws on failure, so a crash is a
/// result rather than the end of the run.
Future<void> _probe(String name, Future<String> Function() body) async {
  _emit('QJS_PROBE START $name');
  final watch = Stopwatch()..start();
  try {
    final detail = await body();
    _report(name, true, '$detail ms=${watch.elapsedMilliseconds}');
  } catch (e) {
    _report(
      name,
      false,
      '${e.runtimeType}: $e ms=${watch.elapsedMilliseconds}',
    );
  }
}

/// A probe that must throw, and throw for the stated reason. The Windows run showed why the
/// reason matters: on the unpatched package everything threw, and a bare "it threw" check scored
/// two false passes. The error text is checked here because nobody reads this run by hand.
Future<void> _probeExpectingThrow(
  String name,
  String expectedError,
  Future<void> Function() body,
) async {
  await _probe(name, () async {
    try {
      await body();
    } catch (e) {
      final text = _oneLine(e);
      if (!text.contains(expectedError)) {
        throw StateError('threw, but not "$expectedError": $text');
      }
      return 'threw as expected: $text';
    }
    throw StateError('completed without throwing, expected "$expectedError"');
  });
}

bool _isInterrupt(Object e) => '$e'.contains('interrupted');

// ---------------------------------------------------------------------------------------------
// The C library's clock(), the very function ffi.cpp's interrupt handler reads, so the probes can
// report how far it moved next to how much wall time passed.

typedef _ClockNative = Long Function();
typedef _ClockDart = int Function();

class _CClock {
  _CClock._(this._clock, this.perSecond, this.library);

  final _ClockDart _clock;

  /// CLOCKS_PER_SEC: 1000 in the Windows CRT, and 1000000 on every POSIX system, as XSI
  /// requires. Android's bionic follows POSIX.
  final int perSecond;
  final String library;

  static _CClock? open() {
    try {
      final (lib, name) = Platform.isWindows
          ? (DynamicLibrary.open('ucrtbase.dll'), 'ucrtbase.dll')
          : Platform.isAndroid
          ? (DynamicLibrary.open('libc.so'), 'libc.so')
          : (DynamicLibrary.process(), 'process');
      final clock = lib.lookupFunction<_ClockNative, _ClockDart>('clock');
      return _CClock._(clock, Platform.isWindows ? 1000 : 1000000, name);
    } catch (_) {
      return null;
    }
  }

  int ticks() => _clock();

  int ms(int fromTicks, int toTicks) =>
      (toTicks - fromTicks) * 1000 ~/ perSecond;
}

final _CClock? _cClock = _CClock.open();

/// CPU time used by the calling thread alone. Neither the deadline nor clock() measures it, which
/// is the point: set beside clock(), it separates a runtime's own work from the rest of the
/// process's.
class _ThreadCpu {
  _ThreadCpu._(this._micros);

  final int Function() _micros;

  static _ThreadCpu? open() {
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        final libc = Platform.isAndroid
            ? DynamicLibrary.open('libc.so')
            : DynamicLibrary.process();
        final gettime = libc
            .lookupFunction<
              Int32 Function(Int32, Pointer<Long>),
              int Function(int, Pointer<Long>)
            >('clock_gettime');
        // struct timespec is two longs on Linux and Android; CLOCK_THREAD_CPUTIME_ID is 3.
        final ts = malloc.allocate<Long>(sizeOf<Long>() * 2);
        return _ThreadCpu._(() {
          if (gettime(3, ts) != 0) throw StateError('clock_gettime failed');
          return ts[0] * 1000000 + ts[1] ~/ 1000;
        });
      }
      if (Platform.isWindows) {
        final kernel32 = DynamicLibrary.open('kernel32.dll');
        final current = kernel32
            .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
              'GetCurrentThread',
            );
        final times = kernel32
            .lookupFunction<
              Int32 Function(
                Pointer<Void>,
                Pointer<Uint64>,
                Pointer<Uint64>,
                Pointer<Uint64>,
                Pointer<Uint64>,
              ),
              int Function(
                Pointer<Void>,
                Pointer<Uint64>,
                Pointer<Uint64>,
                Pointer<Uint64>,
                Pointer<Uint64>,
              )
            >('GetThreadTimes');
        // Creation, exit, kernel and user time, as FILETIMEs in 100 ns units.
        final ft = malloc.allocate<Uint64>(sizeOf<Uint64>() * 4);
        return _ThreadCpu._(() {
          if (times(current(), ft, ft + 1, ft + 2, ft + 3) == 0) {
            throw StateError('GetThreadTimes failed');
          }
          return (ft[2] + ft[3]) ~/ 10;
        });
      }
    } catch (_) {
      // Fall through: the probes report n/a.
    }
    return null;
  }

  int micros() => _micros();
}

final _ThreadCpu? _threadCpu = _ThreadCpu.open();

/// Wall time, clock() time and the calling thread's CPU time for one span, side by side.
class _Span {
  _Span()
    : _startTicks = _cClock?.ticks(),
      _startThreadMicros = _threadCpu?.micros() {
    _watch.start();
  }

  final Stopwatch _watch = Stopwatch();
  final int? _startTicks;
  final int? _startThreadMicros;
  int? _wallMs;
  int? _clockMs;
  int? _threadCpuMs;

  void stop() {
    _watch.stop();
    _wallMs = _watch.elapsedMilliseconds;
    final start = _startTicks;
    final clock = _cClock;
    if (start != null && clock != null) {
      _clockMs = clock.ms(start, clock.ticks());
    }
    final threadStart = _startThreadMicros;
    final thread = _threadCpu;
    if (threadStart != null && thread != null) {
      _threadCpuMs = (thread.micros() - threadStart) ~/ 1000;
    }
  }

  int get wallMs => _wallMs!;
  int? get clockMs => _clockMs;
  int? get threadCpuMs => _threadCpuMs;

  static String _ms(int? ms) => ms == null ? 'n/a' : '${ms}ms';

  @override
  String toString() =>
      'wall=${wallMs}ms clock=${_ms(_clockMs)} thread-cpu=${_ms(_threadCpuMs)}';
}

/// Makes a Dart function callable from JavaScript as a global.
void _setGlobal(FlutterQjs engine, String name, Function value) {
  final setter = engine.evaluate('(k, v) => { globalThis[k] = v; }');
  try {
    setter.invoke([name, value]);
  } finally {
    setter.free();
  }
}

/// One outcome of running a script against a deadline.
class _Run {
  _Run(this.span, {required this.interrupted, this.result, this.error});

  final _Span span;
  final bool interrupted;
  final Object? result;
  final Object? error;

  bool get completed => !interrupted && error == null;

  String get outcome => interrupted
      ? 'interrupted'
      : error != null
      ? 'threw(${_oneLine(error, 80)})'
      : 'completed($result)';

  @override
  String toString() => '$outcome $span';
}

_Run _runAgainstDeadline(FlutterQjs engine, String script) {
  final span = _Span();
  try {
    final result = engine.evaluate(script);
    span.stop();
    return _Run(span, interrupted: false, result: result);
  } catch (e) {
    span.stop();
    return _Run(span, interrupted: _isInterrupt(e), error: e);
  }
}

// ---------------------------------------------------------------------------------------------

/// The deadline every probe from 7 on uses, in milliseconds.
const _deadlineMs = 1000;

/// How long the bounded scripts in probes 8 and 10 run if nothing interrupts them. Four times the
/// deadline, so "interrupted near the deadline" and "ran to the end" cannot be confused.
const _boundMs = 4000;

/// Probe 9's sleeper runs longer, so the spinner beside it can use a full deadline's worth of CPU
/// even on a loaded machine that gives it a third of a core.
const _sleeperBoundMs = 6000;
const _spinnerMs = 5000;

/// A script that spends almost all of its time blocked in a host call rather than computing.
///
/// `hostSleep` is a Dart function that calls dart:io's sleep(), which blocks the thread without
/// using CPU. The empty inner loop is there only so QuickJS polls its interrupt handler, which it
/// does once every 10000 jumps or calls; it costs about a millisecond per 20 ms nap.
///
/// The argument is a number on purpose: a string argument would restart the deadline (probe 10).
String _blockedScript(int boundMs) =>
    '''
(() => {
  const start = Date.now();
  let naps = 0;
  while (Date.now() - start < $boundMs) {
    hostSleep(20);
    naps++;
    for (let i = 0; i < 20000; i++) {}
  }
  return naps;
})()
''';

void _hostSleep(dynamic ms) =>
    sleep(Duration(milliseconds: (ms as num).toInt()));

/// Pure computation for a fixed stretch of wall time.
String _spinScript(int ms) =>
    '''
(() => {
  const start = Date.now();
  let spins = 0;
  while (Date.now() - start < $ms) { spins++; }
  return spins;
})()
''';

String _hostCallScript(String call) =>
    '''
(() => {
  const start = Date.now();
  let calls = 0;
  while (Date.now() - start < $_boundMs) {
    $call;
    calls++;
  }
  return calls;
})()
''';

/// Probe 8's verdict, which probe 9 needs to read its own result.
String? _blockedVerdict;

/// Probe 9's sleeper: the blocked script under the deadline, in a worker isolate of its own, as the
/// extension runtime's will be.
Future<_Run> _sleeperInIsolate() => Isolate.run(() {
  final engine = FlutterQjs(timeout: _deadlineMs);
  try {
    _setGlobal(engine, 'hostSleep', _hostSleep);
    return _runAgainstDeadline(engine, _blockedScript(_sleeperBoundMs));
  } finally {
    engine.close();
  }
});

/// Probe 9's spinner: pure computation with no deadline, in another isolate.
Future<_Run> _spinnerInIsolate() => Isolate.run(() {
  final engine = FlutterQjs();
  try {
    return _runAgainstDeadline(engine, _spinScript(_spinnerMs));
  } finally {
    engine.close();
  }
});

Future<void> _runAll() async {
  // 1. Does the native library load and evaluate at all?
  await _probe('eval-arithmetic', () async {
    final engine = FlutterQjs();
    engine.dispatch();
    final result = await engine.evaluate('1 + 1');
    engine.close();
    if (result != 2) throw StateError('expected 2, got $result');
    return 'got $result';
  });

  // 2. Cold start, measured on its own so the number means something.
  await _probe('eval-cold-start', () async {
    final engine = FlutterQjs();
    engine.dispatch();
    await engine.evaluate('void 0');
    engine.close();
    return 'runtime created and torn down';
  });

  // 3. Promise and async, which the extension contract depends on entirely.
  await _probe('async-awaited-promise', () async {
    final engine = FlutterQjs();
    engine.dispatch();
    final result = await engine.evaluate(
      '(async () => { const v = await Promise.resolve(40); return v + 2; })()',
    );
    engine.close();
    if (result != 42) throw StateError('expected 42, got $result');
    return 'got $result';
  });

  // 4. The first non-negotiable: can the host stop a runaway script?
  await _probeExpectingThrow(
    'watchdog-interrupt-loop',
    'interrupted',
    () async {
      final engine = FlutterQjs(timeout: 1000);
      engine.dispatch();
      try {
        await engine.evaluate('while (true) {}');
      } finally {
        engine.close();
      }
    },
  );

  // 5. The second non-negotiable: is the memory limit enforced?
  await _probeExpectingThrow(
    'watchdog-memory-limit',
    'out of memory',
    () async {
      final engine = FlutterQjs(memoryLimit: 1024 * 1024);
      engine.dispatch();
      try {
        await engine.evaluate(
          'const a = []; while (true) { a.push(new Array(10000).fill(0)); }',
        );
      } finally {
        engine.close();
      }
    },
  );

  // 6. Does the engine survive an interrupt, or is the runtime poisoned? This matters: a pooled
  //    runtime that cannot be reused after one bad extension is a very different design.
  await _probe('watchdog-reuse-after-interrupt', () async {
    final engine = FlutterQjs(timeout: 500);
    engine.dispatch();
    Object? first;
    try {
      await engine.evaluate('while (true) {}');
    } catch (e) {
      first = e;
    }
    if (first == null || !_isInterrupt(first)) {
      engine.close();
      throw StateError('first run was not interrupted: ${_oneLine(first)}');
    }
    final result = await engine.evaluate('7 * 6');
    engine.close();
    if (result != 42) {
      throw StateError('expected 42 after interrupt, got $result');
    }
    return 'engine usable after interrupt, got $result';
  });

  // 7. Control for 8: a busy loop. Its thread is on the CPU the whole time, so wall time and CPU
  //    time advance together and the deadline fires near 1000 ms whichever clock() measures. It
  //    also checks that clock() read from Dart moves at the rate this probe assumes.
  await _probe('deadline-busy-loop', () async {
    final engine = FlutterQjs(timeout: _deadlineMs);
    try {
      final run = _runAgainstDeadline(engine, 'while (true) {}');
      if (!run.interrupted) {
        throw StateError('not interrupted: ${run.outcome} ${run.span}');
      }
      return 'interrupted ${run.span} deadline=${_deadlineMs}ms';
    } finally {
      engine.close();
    }
  });

  // 8. The clock() question itself: a script that spends 95% of its time blocked in a host call,
  //    so wall time runs about twenty times faster than CPU time. With a wall-clock deadline it
  //    is interrupted near 1000 ms; with a CPU-time deadline it never uses 1000 ms of CPU and runs
  //    to its own 4000 ms bound. Nothing in between has an innocent explanation.
  await _probe('deadline-blocked-in-host', () async {
    final engine = FlutterQjs(timeout: _deadlineMs);
    try {
      _setGlobal(engine, 'hostSleep', _hostSleep);
      final run = _runAgainstDeadline(engine, _blockedScript(_boundMs));
      final wall = run.span.wallMs;
      final String verdict;
      if (run.interrupted && wall < _boundMs ~/ 2) {
        verdict = 'wall-clock';
      } else if (run.completed && wall >= _boundMs - 100) {
        verdict = 'cpu-time';
      } else {
        throw StateError('ambiguous: $run');
      }
      _blockedVerdict = verdict;
      return 'verdict=$verdict $run deadline=${_deadlineMs}ms bound=${_boundMs}ms';
    } finally {
      engine.close();
    }
  });

  // 9. Whose CPU time? POSIX clock() counts every thread in the process, not only the one running
  //    the script. A sleeper, as in 8 but with a 6000 ms bound, runs under the 1000 ms deadline
  //    in one worker isolate and uses almost no CPU of its own. A spinner computes for 5000 ms in
  //    another isolate, with no deadline. If the sleeper's deadline counts only its own thread, it
  //    runs to its bound. If it counts the whole process, the spinner's work drains it and the
  //    sleeper is interrupted although its own thread has used a few tens of milliseconds. A
  //    wall-clock deadline interrupts it too, near 1000 ms; probe 8 tells the two apart.
  //
  //    An earlier design spun two runtimes at once and expected a process-wide clock to fire both
  //    at half the deadline. On a loaded emulator the two threads never had a core each, and the
  //    numbers could not tell a shared budget from two separate ones. This one needs no
  //    parallelism, only the spinner using CPU at all.
  await _probe('deadline-other-threads', () async {
    final (sleeper, spinner) = await (
      _sleeperInIsolate(),
      _spinnerInIsolate(),
    ).wait;
    final ownCpu = sleeper.span.threadCpuMs;
    final String verdict;
    if (sleeper.completed && sleeper.span.wallMs >= _sleeperBoundMs - 100) {
      verdict = 'own-thread-cpu';
    } else if (sleeper.interrupted &&
        (ownCpu == null || ownCpu < _deadlineMs ~/ 2)) {
      verdict = switch (_blockedVerdict) {
        'cpu-time' => 'process-cpu',
        'wall-clock' => 'wall-clock',
        _ => 'not-own-thread-cpu',
      };
    } else {
      throw StateError('ambiguous: sleeper $sleeper; spinner $spinner');
    }
    return 'verdict=$verdict sleeper: $sleeper; spinner: $spinner';
  });

  // 10. When does the deadline start? ffi.cpp restarts it on every entry from Dart into QuickJS,
  //     and converting a JS string for Dart is one of those entries. So a script that calls a
  //     host function with a string argument may restart its own deadline on every call. Two
  //     otherwise identical loops, one passing a number and one a string, show whether it does.
  //     The string loop is judged by the deadline's own clock, which probe 8 identified: it
  //     restarts the deadline only if that clock passes 1000 ms without an interrupt.
  await _probe('deadline-host-call-restart', () async {
    _Run loop(String call) {
      final engine = FlutterQjs(timeout: _deadlineMs);
      try {
        _setGlobal(engine, 'hostNumber', (dynamic n) => null);
        _setGlobal(engine, 'hostString', (dynamic s) => null);
        return _runAgainstDeadline(engine, _hostCallScript(call));
      } finally {
        engine.close();
      }
    }

    final number = loop('hostNumber(1)');
    final string = loop("hostString('x')");
    final stringClock = _blockedVerdict == 'wall-clock'
        ? string.span.wallMs
        : string.span.clockMs ?? string.span.wallMs;
    final String verdict;
    if (number.interrupted &&
        string.completed &&
        stringClock > _deadlineMs * 1.2) {
      verdict = 'string-argument-restarts-deadline';
    } else if (number.interrupted && string.interrupted) {
      verdict = 'deadline-not-restarted';
    } else {
      throw StateError('ambiguous: number $number; string $string');
    }
    return 'verdict=$verdict number: $number; string: $string';
  });

  // 11. What the host is told when the limit leaves no room for the error. When an allocation
  //     would pass the limit, QuickJS builds an InternalError("out of memory"), which allocates
  //     too. If the refused request was small, there may be no room left for the error either,
  //     and QuickJS then throws null instead (JS_ThrowError2 does this on purpose, to avoid
  //     recursing). Probe 5 allocates 80 KB arrays, so whether it meets this depends on the
  //     allocator's size classes: on the first CI run API 26 did, and API 35 and Windows did not.
  //     Empty objects make the refused request tiny, which reproduces it on every platform. The
  //     limit is enforced either way; this is about whether the host can tell why.
  await _probeExpectingThrow(
    'watchdog-memory-limit-small-objects',
    'out of memory',
    () async {
      final engine = FlutterQjs(memoryLimit: 1024 * 1024);
      try {
        await engine.evaluate('const a = []; while (true) { a.push({}); }');
      } finally {
        engine.close();
      }
    },
  );

  // 12. The same, in an async function, which is how extensions will run. The null then arrives
  //     as a promise rejection rather than an exception, and before the fork handled it, Dart's
  //     completeError(null) threw instead of completing, so the awaited future never ended. The
  //     timeout turns such a hang into a failure rather than a run with no DONE line.
  await _probeExpectingThrow(
    'watchdog-memory-limit-async',
    'out of memory',
    () async {
      final engine = FlutterQjs(memoryLimit: 1024 * 1024);
      engine.dispatch();
      try {
        await Future<Object?>.value(
          engine.evaluate(
            '(async () => { const a = []; while (true) { a.push({}); } })()',
          ),
        ).timeout(const Duration(seconds: 5));
      } finally {
        engine.close();
      }
    },
  );
}

// ---------------------------------------------------------------------------------------------
// Probes 13 to 19: Kikuyomi's own `ScriptEngine` (packages/source_runtime) over the fork
// (`QuickJsScriptEngine`, packages/platform_adapters). The probes above test the binding; these
// test the interface the extension system is written against, end to end, in a built app — which
// is the only place it can be tested, because `flutter test` does not build a plugin's native
// library.
//
// Probe 14 is the one the fork's per-call deadline was written for: under the old deadline,
// `while (true) hostLog('x')` ran for ever on every platform.

/// The deadline these probes give a call. Short, so a probe that is not stopped is obvious.
const _engineDeadlineMs = 1000;

const _engineLimits = ScriptRuntimeLimits(
  callTimeout: Duration(milliseconds: _engineDeadlineMs),
);

/// A whole extension, small enough to read: one source, one method, one host call inside it.
const _probeExtension = '''
const extension = {
  sources: {
    probe: {
      async getPopular(page) {
        const suffix = await hostGreet('page ' + page);
        return { items: [{ key: 'b' + page, title: 'Book ' + suffix }], hasNextPage: page < 2 };
      },
      boom() {
        const error = new Error('the source is unhappy');
        error.kind = 'RateLimited';
        error.retryAfterMs = 1500;
        throw error;
      },
    },
  },
};
globalThis.__probe_invoke = function (method, args) {
  return extension.sources.probe[method].apply(null, args);
};
''';

/// Runs [body] with an engine of its own, disposed however it ends.
Future<T> _withEngine<T>(
  Future<T> Function(ScriptEngine engine) body, {
  ScriptRuntimeLimits limits = _engineLimits,
}) async {
  final engine = const QuickJsScriptEngineFactory().create(limits);
  try {
    return await body(engine);
  } finally {
    await engine.dispose();
  }
}

/// The exception [body] fails with, or a failure saying it did not fail.
Future<ScriptException> _failure(Future<Object?> Function() body) async {
  final Object? result;
  try {
    result = await body();
  } on ScriptException catch (e) {
    return e;
  }
  throw StateError('expected a ScriptException, got $result');
}

T _expect<T extends ScriptException>(ScriptException actual) => actual is T
    ? actual
    : throw StateError('expected a $T, got ${actual.runtimeType}: $actual');

/// Cancels through [handle] after [wait], from an isolate of its own, and says when it did.
///
/// Top level on purpose: a closure written inside a probe captures that probe's whole context,
/// including the engine itself, and an engine holds a `Future` and cannot be sent to an isolate.
Future<DateTime> _cancelFromAnotherIsolate(
  ScriptCancelHandle handle,
  Duration wait,
) => Isolate.run(() {
  sleep(wait);
  final sentAt = DateTime.now();
  handle.cancel();
  return sentAt;
});

Future<void> _runEngineProbes() async {
  // 13. A whole extension through the interface: load it, call a method with plain-data arguments,
  //     let it await a host function, and read the result back as plain data.
  await _probe('engine-extension-call', () async {
    return _withEngine((engine) async {
      engine.defineHostFunction(
        'hostGreet',
        (args) async => 'of ${args.first}',
      );
      await engine.evaluate(_probeExtension, name: 'probe-extension.js');
      final result = await engine.call('__probe_invoke', [
        'getPopular',
        [1],
      ]);
      if (result is! Map) throw StateError('expected an object, got $result');
      final items = result['items'];
      final title = items is List && items.isNotEmpty && items.first is Map
          ? (items.first as Map)['title']
          : null;
      if (title != 'Book of page 1') {
        throw StateError('expected "Book of page 1", got ${_oneLine(title)}');
      }
      if (result['hasNextPage'] != true) {
        throw StateError('expected hasNextPage, got $result');
      }
      return 'called getPopular(1) and got $title';
    });
  });

  // 14. The deadline the host arms for one call, which is what the fork's third change is for.
  //     A loop calling a host function with a string argument restarted the old deadline on every
  //     call (probe 10 still records that), so it ran until something else stopped it. Under an
  //     armed deadline it must stop near 1000 ms.
  await _probe('engine-deadline-host-call-loop', () async {
    return _withEngine((engine) async {
      var calls = 0;
      engine.defineHostFunction('hostLog', (args) {
        calls++;
        return null;
      });
      await engine.evaluate(
        'globalThis.__probe_spin = function () { while (true) { hostLog("x"); } };',
      );
      final watch = Stopwatch()..start();
      final failure = _expect<ScriptDeadlineException>(
        await _failure(() => engine.call('__probe_spin', [])),
      );
      watch.stop();
      if (watch.elapsedMilliseconds > _engineDeadlineMs * 3) {
        throw StateError(
          'stopped, but ${watch.elapsedMilliseconds}ms after a '
          '${_engineDeadlineMs}ms deadline',
        );
      }
      return 'stopped after ${watch.elapsedMilliseconds}ms and $calls host calls: '
          '${_oneLine(failure)}';
    });
  });

  // 15. A call that is not running cannot be interrupted: an extension awaiting a host promise
  //     that never settles would hang its caller for ever. The engine bounds the future as well as
  //     the script, so this ends at the deadline too.
  await _probe('engine-deadline-idle-call', () async {
    return _withEngine((engine) async {
      final never = Completer<Object?>();
      engine.defineHostFunction('hostWait', (args) => never.future);
      await engine.evaluate(
        'globalThis.__probe_wait = async function () { await hostWait(); return 1; };',
      );
      final watch = Stopwatch()..start();
      final failure = _expect<ScriptDeadlineException>(
        await _failure(() => engine.call('__probe_wait', [])),
      );
      watch.stop();
      if (watch.elapsedMilliseconds > _engineDeadlineMs * 3) {
        throw StateError('waited ${watch.elapsedMilliseconds}ms');
      }
      return 'stopped after ${watch.elapsedMilliseconds}ms: ${_oneLine(failure)}';
    });
  });

  // 16. The memory limit as a typed error, and a runtime that is still usable afterwards, which is
  //     what §3.6's pooling assumes.
  await _probe('engine-memory-limit-and-reuse', () async {
    return _withEngine(
      limits: const ScriptRuntimeLimits(
        memoryBytes: 1024 * 1024,
        callTimeout: Duration(milliseconds: _engineDeadlineMs),
      ),
      (engine) async {
        await engine.evaluate(
          'globalThis.__probe_eat = function () { const a = []; while (true) { a.push({}); } };'
          'globalThis.__probe_add = function (a, b) { return a + b; };',
        );
        final failure = _expect<ScriptMemoryException>(
          await _failure(() => engine.call('__probe_eat', [])),
        );
        final after = await engine.call('__probe_add', [40, 2]);
        if (after != 42) {
          throw StateError('expected 42 after the limit, got $after');
        }
        return 'typed error, and the runtime still answers: ${_oneLine(failure)}';
      },
    );
  });

  // 17. What an extension throws comes back as a typed error rather than a crash. The adapter turns
  //     the thrown value into one of the contract's error kinds; here the point is only that the
  //     engine reports the throw and stays usable.
  await _probe('engine-typed-error', () async {
    return _withEngine((engine) async {
      await engine.evaluate(_probeExtension, name: 'probe-extension.js');
      final failure = _expect<ScriptThrewException>(
        await _failure(
          () => engine.call('__probe_invoke', [
            'boom',
            <Object?>[],
          ]),
        ),
      );
      if (!failure.message.contains('the source is unhappy')) {
        throw StateError('lost the message: ${_oneLine(failure)}');
      }
      return 'reported the throw: ${_oneLine(failure)}';
    });
  });

  // 18. The host can stop a script it is inside: a host function the script itself called cancels
  //     the call, and the call ends as cancelled rather than as a deadline.
  await _probe('engine-cancel-from-host-call', () async {
    return _withEngine(
      // A long deadline, so that a cancellation cannot be mistaken for the watchdog.
      limits: const ScriptRuntimeLimits(callTimeout: Duration(seconds: 10)),
      (engine) async {
        late final ScriptEngine self;
        engine.defineHostFunction('hostStop', (args) {
          self.cancel();
          return null;
        });
        self = engine;
        await engine.evaluate(
          'globalThis.__probe_stoppable = function () { while (true) { hostStop("x"); } };',
        );
        final watch = Stopwatch()..start();
        final failure = _expect<ScriptCancelledException>(
          await _failure(() => engine.call('__probe_stoppable', [])),
        );
        watch.stop();
        return 'cancelled after ${watch.elapsedMilliseconds}ms: ${_oneLine(failure)}';
      },
    );
  });

  // 19. The same from another isolate, which is the case that matters: while a script runs, the
  //     isolate that started it is inside the engine and reaches none of its own messages. The
  //     handle is plain data and the flag behind it is atomic, so another thread can set it.
  await _probe('engine-cancel-from-another-isolate', () async {
    return _withEngine(
      limits: const ScriptRuntimeLimits(callTimeout: Duration(seconds: 10)),
      (engine) async {
        await engine.evaluate(
          'globalThis.__probe_forever = function () { while (true) {} };',
        );
        final handle = engine.cancelHandle;
        if (handle == null) {
          throw StateError('the engine offers no cancel handle');
        }
        final started = DateTime.now();
        final stopping = _cancelFromAnotherIsolate(
          handle,
          const Duration(milliseconds: 500),
        );
        // Let the isolate start before this one disappears into QuickJS.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final watch = Stopwatch()..start();
        final outcome = await _failure(() => engine.call('__probe_forever', []));
        watch.stop();
        final sent = (await stopping).difference(started).inMilliseconds;
        final failure = _expect<ScriptCancelledException>(outcome);
        if (watch.elapsedMilliseconds > 5000) {
          throw StateError(
            'cancelled only after ${watch.elapsedMilliseconds}ms, asked at ${sent}ms',
          );
        }
        return 'cancelled from another isolate after ${watch.elapsedMilliseconds}ms, '
            'asked at ${sent}ms: ${_oneLine(failure)}';
      },
    );
  });
}

// ---------------------------------------------------------------------------------------------
// Probes 20 to 22: the extension protocol on the real engine. Everything above the engine is unit
// tested against a fake one, but the prelude is JavaScript and only QuickJS can say whether it
// runs. These load a small extension through `ExtensionRuntime` with the real prelude and the real
// bridges, and call it through `JsSourceAdapter`, which is how the app will.

/// An extension that touches every part of the prelude on its way to one page of results.
const _protocolExtension = r'''
const extension = {
  sources: {
    probe: {
      async getPopular(page) {
        kikuyomi.log.info('looking at page ' + page);
        const url = new URL('/book/12?q=whale#top', 'https://example.org/index.html');
        const document = await kikuyomi.html.parse(
          '<ul id="results"><li class="card"><a href="/book/12">  Moby-Dick\n</a></li></ul>',
          'https://example.org/'
        );
        const link = document.selectFirst('ul#results > li.card > a');
        const hash = await kikuyomi.crypto.hash('sha256', 'abc');
        await kikuyomi.storage.set('last', String(page));
        const stored = await kikuyomi.storage.get('last');
        const text = new TextDecoder().decode(new TextEncoder().encode('héllo'));
        await new Promise((resolve) => setTimeout(resolve, 10));
        return {
          items: [
            {
              key: link.absUrl('href'),
              title: [
                link.text(),
                text,
                btoa('ok'),
                atob('b2s='),
                hash.slice(0, 8),
                url.searchParams.get('q'),
                url.pathname,
                stored,
                kikuyomi.host.apiVersion,
              ].join('|'),
            },
          ],
          hasNextPage: page < 2,
        };
      },
      async search(query, page) {
        try {
          const document = await kikuyomi.html.parse('<p>x</p>', null);
          document.select('li:has(> a)');
          return { items: [{ key: 'k', title: 'it did not refuse' }], hasNextPage: false };
        } catch (error) {
          return { items: [{ key: 'k', title: error.message }], hasNextPage: false };
        }
      },
      getChapters(bookKey) {
        const error = new Error('that book is gone');
        error.kind = 'NotFound';
        throw error;
      },
    },
  },
};
module.exports = extension;
''';

Future<void> _runProtocolProbes() async {
  final console = InMemoryExtensionLog();

  Future<T> withSource<T>(Future<T> Function(JsSourceAdapter source) body) async {
    final engine = const QuickJsScriptEngineFactory().create(
      const ScriptRuntimeLimits(callTimeout: Duration(seconds: 10)),
    );
    final runtime = await ExtensionRuntime.load(
      engine: engine,
      bundle: ExtensionBundle(
        extensionId: 'org.example.probe',
        code: _protocolExtension,
        domains: DomainAllowlist(['example.org']),
      ),
      host: const HostFacts(appVersion: '0.1.0'),
      bridges: [
        HtmlBridge(),
        const CryptoBridge(),
        LogBridge(extensionId: 'org.example.probe', sink: console),
        StorageBridge(
          extensionId: 'org.example.probe',
          store: InMemoryExtensionStore(),
        ),
      ],
    );
    try {
      return await body(
        await JsSourceAdapter.open(runtime: runtime, sourceKey: 'probe'),
      );
    } finally {
      await runtime.dispose();
    }
  }

  // 20. The prelude, the protocol and the adapter together: an extension that uses the log, the
  //     html bridge, the crypto bridge, storage, URL, TextEncoder, TextDecoder, atob, btoa and a
  //     timer, and whose result is decoded into the contract's types.
  await _probe('protocol-extension-end-to-end', () async {
    return withSource((source) async {
      final page = await source.getPopular(1);
      if (page.items.length != 1) {
        throw StateError('expected one book, got ${page.items.length}');
      }
      final book = page.items.single;
      const expected =
          'Moby-Dick|héllo|b2s=|ok|ba7816bf|whale|/book/12|1|1.0';
      if (book.title != expected) {
        throw StateError('expected "$expected", got "${book.title}"');
      }
      if (book.key != 'https://example.org/book/12') {
        throw StateError('absUrl gave ${book.key}');
      }
      if (!page.hasNextPage) throw StateError('expected another page');
      if (!console.messages.any((m) => m.text == 'looking at page 1')) {
        throw StateError('the log bridge was not reached');
      }
      return 'the whole prelude ran: ${book.title}';
    });
  });

  // 21. The selectors Phase 0 found `package:html` silently wrong about. The contract says they
  //     throw; an extension catches the error and reads its message.
  await _probe('protocol-refused-selector', () async {
    return withSource((source) async {
      final page = await source.search(
        SearchQuery(text: 'whale', filters: FilterValues(const {})),
        1,
      );
      final message = page.items.single.title;
      if (!message.contains('is not supported')) {
        throw StateError('expected a refusal, got "$message"');
      }
      return 'refused, and the extension could read why: $message';
    });
  });

  // 22. An error thrown with the SDK's shape arrives as its own kind, which is the whole reason
  //     nothing is thrown across the boundary.
  await _probe('protocol-error-kind', () async {
    return withSource((source) async {
      try {
        await source.getChapters('b1');
      } on NotFoundException catch (error) {
        return 'kept its kind: ${_oneLine(error)}';
      } on SourceException catch (error) {
        throw StateError('expected NotFound, got ${error.kind}: $error');
      }
      throw StateError('expected the call to fail');
    });
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _emit('QJS_PROBE INFO probe=spike-a-qjs-probe');
  _emit('QJS_PROBE INFO os=${Platform.operatingSystem}');
  _emit(
    'QJS_PROBE INFO os-version=${_oneLine(Platform.operatingSystemVersion)}',
  );
  _emit('QJS_PROBE INFO cpus=${Platform.numberOfProcessors}');
  _emit('QJS_PROBE INFO dart=${_oneLine(Platform.version, 60)}');
  final clock = _cClock;
  _emit(
    clock == null
        ? 'QJS_PROBE INFO clock=unavailable'
        : 'QJS_PROBE INFO clock=${clock.library} clocks-per-sec=${clock.perSecond}',
  );

  await _runAll();
  await _runEngineProbes();
  await _runProtocolProbes();

  _emit('QJS_PROBE DONE passed=$_passed failed=$_failed');

  if (Platform.isAndroid || Platform.isIOS) {
    // Mobile apps are not meant to exit themselves. Leave the results on screen instead, for
    // anyone running the probe by hand.
    runApp(_Results(List.of(_lines)));
    return;
  }
  await stdout.flush();
  exit(_failed == 0 ? 0 : 1);
}

class _Results extends StatelessWidget {
  const _Results(this.lines);

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      // No SafeArea: without a WidgetsApp there may be no MediaQuery to read insets from.
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 48, 12, 12),
          child: Text(
            lines.join('\n'),
            style: const TextStyle(color: Color(0xFF000000), fontSize: 11),
          ),
        ),
      ),
    );
  }
}
