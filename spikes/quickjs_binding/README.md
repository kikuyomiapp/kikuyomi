# Spike (a): QuickJS binding selection

**Question.** Which QuickJS binding for Dart meets the criteria in `docs/architecture.md` §3.1?
This is the most important dependency in the project: the extension runtime is built on it, and
every source extension ever written runs inside it.

**Status.** Desk evaluation and source-level verification complete. Hands-on build and measurement
not started. The recommendation below is provisional until a real build runs on Windows and
Android.

## Criteria (§3.1)

1. The same engine on every platform, so an extension behaves identically everywhere.
2. Promise and async support with a host-driven job loop.
3. Access to the **interrupt handler**, so a runaway script can be stopped.
4. A per-runtime **memory limit**.
5. Builds for Android, Windows and iOS.
6. Safe use inside a Dart isolate.
7. Recent maintenance activity.

Criteria 3 and 4 are not negotiable. They are the reason §3.1 chose QuickJS over JavaScriptCore:
extension code is untrusted, and without them one bad extension can hang or exhaust the app with
no host-side recovery.

## Method

Package documentation was treated as unreliable and checked against source. Each candidate archive
was downloaded from pub.dev, extracted, and its C/C++ bridge and Dart FFI layer read directly for
`JS_SetInterruptHandler`, `JS_SetMemoryLimit` and `JS_SetMaxStackSize`. **This changed the
conclusion**: the documentation comparison and the source comparison disagree.

## Results

| | `flutter_qjs` 0.3.7 | `quickjs_engine` 0.1.5 | `quickjs` (lindeer) 1.0.1 | Rust `rquickjs` + FRB |
|---|---|---|---|---|
| Same engine everywhere | Yes | Yes, QuickJS-NG 0.14.0 | Yes | Yes |
| Promise / job loop | Yes, `engine.dispatch()` | engine supports it | async manager | Yes, `AsyncRuntime` |
| **Interrupt handler** | **Yes — installed in `ffi.cpp:95`** | **No — bridge never installs one** | Not found | **Yes, host closure** |
| **Memory limit** | **Yes — `jsSetMemoryLimit`, exposed in Dart** | **Hardcoded 64 MB, not settable** | Not found | **Yes, settable** |
| Stack limit | Yes, `stackSize` | `jsSetMaxStackSize` exported | Not found | Yes |
| Android / Windows / iOS | Yes (all but web) | Yes | Yes | Yes, with Rust targets |
| Isolate-safe | Yes, `IsolateQjs` | Not documented | Yes | To be determined |
| Flutter support | Yes | Yes | **No — pure Dart only** | Yes |
| Maintenance | **None, 4 years** | Active but incidental | Low | Active, FRB is a Flutter Favorite |
| Extra toolchain | None | None | None | **Rust, dev machine + 3 CI runners** |

### `flutter_qjs` has both non-negotiables, despite documenting neither

`cxx/ffi.cpp:88` installs an interrupt handler on every runtime it creates:

```c
DLLEXPORT JSRuntime *jsNewRuntime(JSChannel channel, int64_t timeout) {
  JSRuntime *rt = JS_NewRuntime();
  RuntimeOpaque *opaque = new RuntimeOpaque({channel, timeout, 0});
  JS_SetRuntimeOpaque(rt, opaque);
  JS_SetHostPromiseRejectionTracker(rt, js_promise_rejection_tracker, opaque);
  JS_SetModuleLoaderFunc(rt, nullptr, js_module_loader, opaque);
  JS_SetInterruptHandler(rt, js_interrupt_handler, opaque);
  return rt;
}
```

`jsSetMemoryLimit` and `jsSetMaxStackSize` are exported at `ffi.cpp:142` and `:147`, bound in
`lib/src/ffi.dart`, and surfaced as `timeout`, `memoryLimit` and `stackSize` constructor
parameters on both `FlutterQjs` and `IsolateQjs`. The isolate variant forwards them through its
spawn message. So the whole watchdog story is reachable from Dart today.

Three limitations of its handler, which matter for §3.6:

- It implements a **fixed timeout policy, not a host callback**. The host cannot decide per-tick
  whether to continue, so cancelling because the user navigated away is not possible without
  patching the bridge. `rquickjs` hands the host a closure and does allow this.
- It uses `clock()`, whose meaning differs by platform: CPU time on POSIX, wall-clock since
  process start on Windows with MSVC. The same timeout value therefore does not mean the same
  thing on Android and Windows. This needs measuring, and probably patching.
- Once it fires it sets `op->start = 0`, disabling itself until the next evaluation begins.

### `quickjs_engine` cannot stop a runaway script

Its bridge (`native/cxx/libfastdev_quickjs_runtime.cpp`) hardcodes a 64 MB memory limit at line 34
and exports `jsSetMaxStackSize`, but **never calls `JS_SetInterruptHandler`**. The matches for that
symbol are in the vendored `quickjs-libc.c`, which is the engine's own standard library, not the
binding. There is no way for the host to interrupt a script. It fails criterion 3 outright.

This is consistent with its origin: it exists to run inline `<script>` blocks for the SVG renderer
at `denisnadey/flutter_full_svg_support`, where scripts are trusted and short. A hostile extension
is not that workload.

### Others

`quickjs` (lindeer) does not support Flutter — it targets `native_assets_cli` and states it works
with any Dart app "not flutter currently". `flutter_js` was eliminated before source review: it
runs **JavaScriptCore on iOS and macOS**, failing criterion 1 and reintroducing the watchdog
weakness §3.1 moved away from. It stays on file as the fallback the `ScriptEngine` interface
exists to permit, should Apple review ever demand it.

## Where this leaves the decision

The choice is no longer "the packages lack the features, so use Rust". It is:

**A. Adopt `flutter_qjs`, and fork it.** Meets every functional criterion today, verified in
source. Adds no toolchain. Keeps `source_runtime` a pure-Dart + FFI package as §2.4 requires. MIT
licensed, so a fork is compatible with Apache-2.0. The cost is owning a small C++ bridge and its
per-platform builds, and the risk is that four years of Dart FFI, NDK and Gradle drift have broken
it — which is cheap to find out.

**B. Rust `rquickjs` via `flutter_rust_bridge`.** Actively maintained, a genuinely host-driven
interrupt callback rather than a fixed timeout, and the route Mangayomi already took. The cost is
a Rust toolchain on the development machine and in all three CI jobs, Android NDK r26+, Xcode 15+,
and an unresolved conflict with §2.4: FRB generates Flutter-coupled glue, and `source_runtime` is
specified as pure Dart.

Provisional recommendation is **A**, with **B** as the documented fallback, on the grounds that it
satisfies the criteria with the least toolchain and no architecture change. That is contingent on
the build test below.

## Next, in order

1. **Does `flutter_qjs` still build?** Add it to a throwaway Flutter app and run on Windows, then
   Android, against Flutter 3.47.3 / Dart 3.13.3. This is the single fact that decides A vs B, and
   it is a morning's work. If it does not build, measure how far off it is before abandoning it.
2. Measure: cold runtime start, warm evaluation, memory per runtime, and the interval between the
   interrupt firing and control returning to Dart.
3. Confirm `clock()` semantics on Windows versus Android and decide whether the handler needs
   replacing with a wall-clock deadline.
4. Prototype the host-callback patch, since the fixed-timeout policy is likely too coarse for
   §3.6.
5. If A fails: establish what FRB costs the three CI jobs, and whether `source_runtime` can stay
   pure Dart.

## Second half of this spike

CSS selector coverage in the Dart `html` parser, against the selectors real audiobook catalogue
pages need. Not started.
