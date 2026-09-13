// Spike (a) probe. Throwaway.
//
// Answers one question: does flutter_qjs 0.3.7, unreleased for four years, still build and run
// against Flutter 3.47.3 / Dart 3.13.3, and do the interrupt handler and memory limit that
// ffi.cpp exposes actually work from Dart?
//
// This is a console probe wearing a Flutter app as a costume, because the plugin's native library
// is only present in a built Flutter application. It prints results and exits.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_qjs/flutter_qjs.dart';

int _passed = 0;
int _failed = 0;

void _report(String name, bool ok, String detail) {
  final tag = ok ? 'PASS' : 'FAIL';
  ok ? _passed++ : _failed++;
  stdout.writeln('[$tag] $name :: $detail');
}

/// Wraps a probe so a thrown exception is a result, not a crash.
Future<void> _probe(String name, Future<String> Function() body) async {
  final started = DateTime.now();
  try {
    final detail = await body();
    final ms = DateTime.now().difference(started).inMilliseconds;
    _report(name, true, '$detail (${ms}ms)');
  } catch (e) {
    final ms = DateTime.now().difference(started).inMilliseconds;
    _report(name, false, '${e.runtimeType}: $e (${ms}ms)');
  }
}

/// Same, but the probe is expected to throw. Not throwing is the failure.
Future<void> _probeExpectingThrow(
  String name,
  Future<void> Function() body,
) async {
  final started = DateTime.now();
  try {
    await body();
    final ms = DateTime.now().difference(started).inMilliseconds;
    _report(
      name,
      false,
      'completed without throwing, expected a throw (${ms}ms)',
    );
  } catch (e) {
    final ms = DateTime.now().difference(started).inMilliseconds;
    final text = e.toString().replaceAll('\n', ' ');
    final clipped = text.length > 120 ? '${text.substring(0, 120)}...' : text;
    _report(name, true, 'threw as expected: $clipped (${ms}ms)');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  stdout.writeln('--- spike (a): flutter_qjs 0.3.7 probe ---');
  stdout.writeln('Dart ${Platform.version}');
  stdout.writeln('');

  // 1. Does the native library load and evaluate at all?
  await _probe('eval: arithmetic', () async {
    final engine = FlutterQjs();
    engine.dispatch();
    final result = await engine.evaluate('1 + 1');
    engine.close();
    if (result != 2) throw StateError('expected 2, got $result');
    return 'got $result';
  });

  // 2. Cold start, measured on its own so the number means something.
  await _probe('eval: cold start', () async {
    final engine = FlutterQjs();
    engine.dispatch();
    await engine.evaluate('void 0');
    engine.close();
    return 'runtime created and torn down';
  });

  // 3. Promise and async, which the extension contract depends on entirely.
  await _probe('async: awaited promise', () async {
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
  await _probeExpectingThrow('watchdog: interrupt an infinite loop', () async {
    final engine = FlutterQjs(timeout: 1000);
    engine.dispatch();
    try {
      await engine.evaluate('while (true) {}');
    } finally {
      engine.close();
    }
  });

  // 5. The second non-negotiable: is the memory limit enforced?
  await _probeExpectingThrow('watchdog: enforce memory limit', () async {
    final engine = FlutterQjs(memoryLimit: 1024 * 1024);
    engine.dispatch();
    try {
      await engine.evaluate(
        'const a = []; while (true) { a.push(new Array(10000).fill(0)); }',
      );
    } finally {
      engine.close();
    }
  });

  // 6. Does the engine survive an interrupt, or is the runtime poisoned? This matters: a pooled
  //    runtime that cannot be reused after one bad extension is a very different design.
  await _probe('watchdog: reuse after interrupt', () async {
    final engine = FlutterQjs(timeout: 500);
    engine.dispatch();
    try {
      await engine.evaluate('while (true) {}');
    } catch (_) {
      // expected
    }
    final result = await engine.evaluate('7 * 6');
    engine.close();
    if (result != 42)
      throw StateError('expected 42 after interrupt, got $result');
    return 'engine usable after interrupt, got $result';
  });

  stdout.writeln('');
  stdout.writeln('--- $_passed passed, $_failed failed ---');
  await stdout.flush();
  exit(_failed == 0 ? 0 : 1);
}
