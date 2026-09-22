# flutter_qjs: Kikuyomi's maintained fork

This directory is Kikuyomi's fork of [`flutter_qjs`](https://github.com/ekibun/flutter_qjs), the
QuickJS binding that source extensions will run in. ADR-0001 chose it on the condition that the
project carries it as a maintained fork: the published package has had no release for four years
and does not run on current Dart. `README.md` is upstream's own documentation, kept unchanged.

## Upstream

- **Package:** `flutter_qjs` 0.3.7, the archive published on pub.dev
  (`flutter_qjs-0.3.7.tar.gz`, SHA-256
  `123b6a2c95ceb4343a15a2bf4eb8e22f6f30d17c291b7a6c71f759906f817525`).
- **Engine:** QuickJS 2021-03-27, vendored by upstream in `cxx/quickjs/`.
- **Left out:** `example/`, `coverage/` and `flutter_qjs.iml`. None of them is part of the plugin.

The first commit that added this directory is that archive unchanged, so `git log -p` on it shows
every change the fork has made.

## Licences

`LICENSE` is flutter_qjs's MIT licence and `cxx/quickjs/LICENSE` is QuickJS's MIT licence. Both
stay with the code. Changes made here are offered under the same MIT licence as the files they
change.

## Changes from upstream

Only what is needed to build and run. Each is its own commit.

1. **Dart 3.13** (`lib/src/ffi.dart`). Published 0.3.7 fails every call with
   `Pointer.fromFunction cannot be called dynamically`. `channelDispacher` now returns a
   non-nullable pointer, falling back to `nullptr`, and `Pointer.fromFunction` gets its explicit
   `<_JSChannelNative>` type argument. This is `spikes/quickjs_binding/flutter_qjs-dart313.patch`.
2. **Android build** (`android/build.gradle`, `android/src/main/AndroidManifest.xml`). Upstream's
   Gradle file was written for AGP 3.5 and Gradle 5 and does not load in a current Flutter app.
   Removed: the `buildscript` block pinning AGP 3.5.0 and Kotlin 1.3.50, the `jcenter()` and
   JitPack repositories (`jcenter()` no longer exists in Gradle 9), the explicit
   `kotlin-android` plugin, the `kotlin-stdlib-jdk7` dependency, `lintOptions`, and the pin to
   CMake 3.10.2. Added: the `namespace` AGP 8 requires, in place of the manifest's `package`
   attribute. Changed: `compileSdk` 28 to 36 and `minSdk` 16 to 21, the lowest the NDK builds
   for, and Java and Kotlin both target 17. Kotlin is compiled the way Flutter's current plugin
   template expects: by AGP's built-in Kotlin, or by the Kotlin plugin that Flutter applies
   when an app opts out of it. The native build itself, `src/main/cxx/CMakeLists.txt`, is
   unchanged.
3. **Clang 15 and later** (`cxx/quickjs/quickjs.c`). `JS_GetClassID`, which upstream added to
   its copy of QuickJS for the bridge's finalizer, returned `NULL` from a function whose result
   is the integer `JSClassID`. Clang 15 made that conversion an error, so the NDK's clang 19
   refused the file. It now returns 0, which QuickJS never assigns as a class id. MSVC only
   warned, which is why the Windows build never noticed.
4. **Wall-clock deadline** (`cxx/ffi.cpp`). The `timeout` was measured with `clock()`, which is
   wall time in the Windows CRT but CPU time for the whole process on POSIX. On Android that
   meant a script blocked in a host call was never interrupted, and a runtime's deadline was
   drained by every other thread in the process: in the probe, a runtime that had used 26 ms of
   CPU was interrupted because another isolate was computing. The deadline now reads
   `std::chrono::steady_clock`, so one timeout means the same elapsed time on every platform.
   Windows behaves as before.
5. **No `null` reaches Dart as an error** (`lib/src/wrapper.dart`). When the memory limit leaves
   no room to build QuickJS's "out of memory" error, QuickJS throws `null` instead
   (`JS_ThrowError2`, on purpose). `evaluate` rethrew it as a Dart `throw null`, so the host got
   `TypeError: type 'Null' is not a subtype of type 'Object'`; in an async function the promise
   rejected with `null`, `completeError(null)` threw, and the awaited future never completed.
   `_parseJSException` now returns `JSError('InternalError: out of memory (QuickJS threw null)')`
   for a thrown `null`, and a plain `InternalError` for anything else with no Dart equivalent,
   such as `undefined`. A promise rejected with `null` or `undefined` completes with an
   `InternalError` saying it may be out of memory. A script's own `throw null` is reported as out
   of memory too; nothing tells the two apart.

6. **A deadline the host arms for one call** (`cxx/ffi.cpp`, `lib/src/ffi.dart`,
   `lib/src/engine.dart`). The `timeout` given to `jsNewRuntime` is restarted by `js_begin_call`,
   which runs on every entry from Dart into QuickJS — an evaluation, a call, a promise job, and
   converting a string argument of a host call — so it bounds each stretch between host calls
   rather than a call: `while (true) log('x')` ran forever under it, on every platform.
   `jsArmDeadline(rt, ms)` now sets a deadline that only the host clears, and while one is armed
   `js_begin_call` leaves it alone and the per-entry timeout is not consulted at all.
   `jsCancel(rt)` asks for the running script to stop, and `jsTakeInterruptReason(rt)` says which
   of the three stopped it, because QuickJS reports every interrupt as
   `InternalError: interrupted`. The deadline and the cancellation flag are `std::atomic`, so a
   host in another thread or isolate can cancel a script whose own isolate is inside QuickJS;
   `FlutterQjs.cancelRuntimeAt(address)` is that call, with the address from
   `FlutterQjs.runtimeAddress`. The Dart side adds `armDeadline`, `disarmDeadline`, `cancel`,
   `runtimeAddress`, `cancelRuntimeAt` and `takeInterruptReason` to `FlutterQjs`, and exports
   `JSInterruptReason`. `IsolateQjs` is unchanged: Kikuyomi confines a runtime to its own worker
   isolate (§3.6) and drives `FlutterQjs` there directly.
7. **`ffi` 2** (`pubspec.yaml`). The constraint was `^1.0.0`, which cannot resolve beside packages
   that need `ffi` 2, such as `smtc_windows`. It is now `>=1.0.0 <3.0.0`; the Dart source here
   uses only `malloc`, `Utf8` and `toNativeUtf8`, which both majors have.

## Known defects

Found by the probe, not yet fixed. `spikes/quickjs_binding/README.md` has the evidence.

- **The probe has run on x86_64 emulators and on Windows, not on an arm64 device.**
- **A cancellation from another isolate needs the runtime to be open.** `cancelRuntimeAt` writes to
  the runtime's opaque, so cancelling one that has been closed writes to freed memory. The owner
  of the runtime has to keep the address from being used after `close()`.

## Using it

It is not published and must never be published under upstream's name. Depend on it by path:

```yaml
dependencies:
  flutter_qjs:
    path: <relative path to>/third_party/flutter_qjs
```

It sits outside the pub workspace, so `flutter analyze app packages` and
`dart format app packages` do not cover it. Its test is the probe in
`spikes/quickjs_binding/qjs_probe`, which `.github/workflows/android-emulator.yml` runs on Android
emulators.
