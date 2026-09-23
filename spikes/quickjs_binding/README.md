# Spike (a): QuickJS binding selection

**Question.** Which QuickJS binding for Dart meets the criteria in `docs/architecture.md` §3.1?
This is the most important dependency in the project: the extension runtime is built on it, and
every source extension ever written runs inside it.

**Status.** **Done.** Desk evaluation, source-level verification, a Windows build-and-run and an
Android run on API 26 and API 35 emulators in CI are complete. `flutter_qjs`, vendored as
Kikuyomi's fork in `third_party/flutter_qjs`, runs on Flutter 3.47.3 / Dart 3.13.3, and all twelve
probes pass on Windows and on both API levels. Android forced two fixes into the fork: the
interrupt deadline measured CPU time for the whole process there and is now wall-clock, and when
the memory limit left no room for an error the host was handed `null` and now gets
`InternalError: out of memory`. ADR-0001 is Accepted.

The gap that was left for `source_runtime` — a host call restarts the deadline — is now closed in
the fork, and the probe has grown seven more probes that drive Kikuyomi's own `ScriptEngine`
rather than the binding. See "Kikuyomi's ScriptEngine" below. The spike has therefore outlived its
throwaway purpose in one respect: it is where the engine is tested on a device, because
`flutter test` does not build a plugin's native library.

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
  thing on Android and Windows. This needs measuring, and probably patching. (Measured on
  Android and patched in the fork: see below.)
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

## Hands-on result (Windows)

`spikes/quickjs_binding/qjs_probe` is a throwaway Flutter app that loads the plugin and probes it.
It is a console probe wearing a Flutter app as a costume, because the native library only exists
inside a built Flutter application.

**Published 0.3.7 compiles but does not run.** Every call fails immediately with:

```
UnsupportedError: Unsupported operation: Pointer.fromFunction cannot be called dynamically.
```

This is four years of Dart FFI drift, exactly the risk the ADR named. `lib/src/ffi.dart:205`
calls `Pointer.fromFunction(channelDispacher)` and lets the type argument be inferred from the
surrounding call. Modern Dart FFI requires it to be explicit and statically known. The callback
also returns a nullable pointer, which no longer matches the native signature.

**Three lines fix it.** See `flutter_qjs-dart313.patch`: make `channelDispacher` return a
non-nullable pointer, fall back to `nullptr.cast<JSValue>()`, and give `Pointer.fromFunction` its
explicit `<_JSChannelNative>` type argument. With that patch applied, all six probes pass:

| Probe | Result | Time |
|---|---|---|
| eval arithmetic | `2` | 26 ms |
| cold runtime start and teardown | ok | 1 ms |
| async, `await Promise.resolve(40) + 2` | `42` | 21 ms |
| **interrupt an infinite loop** (`timeout: 1000`) | `InternalError: interrupted` | **1012 ms** |
| **memory limit** (`memoryLimit: 1 MB`) | `InternalError: out of memory` | 18 ms |
| **engine reusable after an interrupt** | `42` | 504 ms |

The last row matters for §3.6: an interrupted runtime is **not poisoned**, so a pooled runtime
survives a hostile extension and can be reused rather than rebuilt.

The interrupt fired 12 ms past a 1000 ms deadline, so on Windows the `clock()`-based handler
behaves as wall-clock time, as MSVC defines it. What it does on Android is measured below.

### Two caveats about this run

The build failed once on first invocation and succeeded unchanged on the second, which looks like
the known Flutter Windows plugin-symlink race during initial CMake generation rather than anything
to do with this package. Worth watching in CI.

The probe's "expected a throw" helper cannot distinguish a throw for the right reason from a throw
because everything is broken. On the unpatched run it scored two false passes for exactly that
reason. The passing figures above were re-read individually against their error text. The probe
now checks the error text itself, which is what caught the Android memory-limit failure below:
the old check would have counted it a pass.

### Windows, again, with the fork

The probe now runs against the vendored fork in `third_party/flutter_qjs` and has twelve probes
(see Android below for what the new ones do). On the development machine, with the fork as it
stands, all twelve pass: the interrupt fires at 1000 ms, the blocked script is interrupted at
1020 ms (the deadline is wall-clock, as it always was on Windows), the sleeper beside a spinning
isolate is interrupted at 1020 ms, a loop calling a host function with a string runs its full
4000 ms bound, 1.8 million calls, uninterrupted, and both out-of-memory cases report
`InternalError: out of memory`. `windows/flutter/CMakeLists.txt` had never been committed,
because the root `.gitignore`'s `flutter/` matches it too, so the probe did not build on Windows
from a fresh clone; it now does.

## Android: emulators in CI

The development machine still cannot run an emulator (see the end of this section), so the probe
runs on GitHub's Linux runners, which have KVM. `.github/workflows/android-emulator.yml` builds it
as an x86_64 release APK against the fork, boots x86_64 `google_apis` emulators at **API 26**, the
app's minimum under ADR-0012, and **API 35**, with two cores each, lets each settle for 60 s after
boot, and runs `run_probe_on_device.sh`. That script installs and launches the probe, waits for its
`QJS_PROBE DONE` line in logcat, and fails the job if any probe fails or no DONE line appears. The
probe lines, the app's log and the whole logcat are uploaded as artifacts. It runs on every push
that touches the fork, this spike or the workflow, and on demand.

**All twelve probes pass on both API levels** in
[run 6](https://github.com/kikuyomiapp/kikuyomi/actions/runs/35758353441), at commit `9d03405`.
Getting there took four fork changes that Windows could not have shown, each recorded in
`third_party/flutter_qjs/README.kikuyomi.md`:

- upstream's Gradle file was written for AGP 3.5 and Gradle 5, and now follows Flutter 3.47's
  plugin template;
- QuickJS as upstream vendored it returned `NULL` from a function whose result is an integer,
  which MSVC only warned about and the NDK's clang 19 refuses;
- the interrupt deadline measured `clock()`, which on Android is CPU time for the whole process,
  and now measures wall time;
- when the memory limit left no room to build an error, the host was handed `null`, and now gets
  `InternalError: out of memory`.

### What the new probes do

Probes 1 to 6 are the Windows six, with the same meaning. Probes 7 to 10 measure the interrupt
deadline, and pass when the measurement is unambiguous, stating what they found; probes 11 and 12
check what the host is told when memory runs out.

- **7, busy loop.** Control: wall and CPU time advance together, so the deadline fires near
  1000 ms whichever it counts.
- **8, blocked in a host call.** A script that spends 95% of its time in a Dart host function
  that calls `sleep()`, with a 1000 ms deadline and a 4000 ms bound of its own. A wall-clock
  deadline interrupts it near 1000 ms; a CPU-time deadline never sees 1000 ms of CPU and lets it
  run to its bound. This is the question the spike left open.
- **9, other threads.** The same sleeping script in one worker isolate, beside a runtime that
  computes for 5000 ms in another isolate, with no deadline. If the sleeper's deadline counts
  only its own thread, it runs to its bound; if it counts the whole process, the spinner drains
  it. An earlier design, two spinners expected to fire at half the deadline, could not tell a
  shared budget from two separate ones on a loaded two-core emulator and was replaced.
- **10, host-call restart.** Two loops calling a host function, one with a number and one with a
  string, judged by the deadline's own clock.
- **11, memory limit, small objects.** Like probe 5, but filling the memory with empty objects,
  so that the allocation the limit refuses is tiny.
- **12, memory limit, async.** Probe 11 inside an async function, awaited with a timeout, which
  is how extensions will run.

Every deadline probe reports wall time, `clock()` (read from Dart through FFI, the very function
upstream's handler used) and the calling thread's own CPU time.

### Results

Two runs matter. [Run 3](https://github.com/kikuyomiapp/kikuyomi/actions/runs/35661107724), at
commit `403a2ab`, is the fork with upstream's `clock()` deadline, before probes 11 and 12
existed; it shows the problem. [Run 6](https://github.com/kikuyomiapp/kikuyomi/actions/runs/35758353441),
at `9d03405`, is the fork as it stands, with the wall-clock deadline and the null-exception fix.
Times are wall-clock milliseconds; "CPU" is the script thread's own.

| Probe | API 26, run 3 | API 35, run 3 | API 26, run 6 | API 35, run 6 |
|---|---|---|---|---|
| 1 eval arithmetic | `2`, 1 ms | `2`, 5 ms | `2`, 0 ms | `2`, 2 ms |
| 2 cold start | ok, 0 ms | ok, 0 ms | ok, 0 ms | ok, 0 ms |
| 3 async, awaited promise | `42`, 86 ms | `42`, 481 ms | `42`, 40 ms | `42`, 1 ms |
| 4 **interrupt an infinite loop** | interrupted, 1077 ms | interrupted, 1045 ms | interrupted, 1001 ms | interrupted, 1001 ms |
| 5 **memory limit** | **FAIL**: `TypeError`, 1 ms | out of memory, 1 ms | out of memory (null thrown), 1 ms | out of memory, 1 ms |
| 6 **reuse after interrupt** | `42`, 509 ms | `42`, 514 ms | `42`, 501 ms | `42`, 501 ms |
| 7 busy loop | fired at 1003 ms, `clock()` 1000 | 1011 ms, `clock()` 1000 | 1000 ms, `clock()` 954 | 1000 ms, `clock()` 984 |
| 8 blocked in a host call | **ran to its bound**: 4006 ms, `clock()` 110 | **ran to its bound**: 3999 ms, `clock()` 102 | interrupted at 1020 ms, CPU 15 | interrupted at 1019 ms, CPU 25 |
| 9 other threads | sleeper **interrupted at 975 ms with 26 ms of its own CPU** | same, 1070 ms, 26 ms CPU | interrupted at 1005 ms, CPU 14 | interrupted at 1008 ms, CPU 24 |
| 10 host-call restart | string loop ran 4000 ms, 232k calls | 3999 ms, 788k calls | 3999 ms, 2.5M calls | 3999 ms, 895k calls |
| 11 memory limit, small objects | not yet written | not yet written | out of memory (null thrown), 1 ms | out of memory (null thrown), 2 ms |
| 12 memory limit, async | not yet written | not yet written | out of memory (null rejection), 1 ms | out of memory (null rejection), 3 ms |
| Verdicts, 8 / 9 / 10 | cpu-time / process-cpu / restarts | cpu-time / process-cpu / restarts | wall-clock / wall-clock / restarts | wall-clock / wall-clock / restarts |
| **Total** | 9 of 10 | 10 of 10 | **12 of 12** | **12 of 12** |

Run 4 ([35662512078](https://github.com/kikuyomiapp/kikuyomi/actions/runs/35662512078)) and
run 5 ([35663545249](https://github.com/kikuyomiapp/kikuyomi/actions/runs/35663545249)) had the
wall-clock deadline but not yet the null fix. Their deadline figures match run 6's, and probe 5
failed on API 26 in both, as in run 3: three runs out of three, so it is deterministic there.

The load average when the probe started was 2 to 3 on API 26 and 16 to 20 on API 35, both on two
cores: the API 35 image is still busy a minute after boot. On an earlier run
([run 2](https://github.com/kikuyomiapp/kikuyomi/actions/runs/35659857271)), with no settling
time, API 35 gave the probe about a third of a core, and the busy loop reached its 1000 ms
`clock()` deadline after **3644 ms** of wall time.

### The `clock()` finding: CPU time for the whole process

On Android, upstream's deadline counted `clock()`, which bionic defines as CPU time for the
**whole process**, every thread included, not elapsed time and not the script's own thread. Run 3
shows all three consequences on both API levels:

- **Time a script spends blocked does not count.** The blocked script ran its whole 4000 ms bound
  under a 1000 ms deadline while `clock()` moved about 100 ms.
- **Every other thread's work does count.** The sleeper was interrupted at about 1000 ms having
  used 26 ms of CPU itself: the spinning isolate beside it drained its deadline. With §2.7's pool
  of runtimes in worker isolates, every runtime's deadline would be drained by every other
  runtime, and by the UI, raster and audio threads.
- **Competition for the CPU stretches it.** On the loaded API 35 emulator a 1000 ms deadline took
  3644 ms to fire.

So the same timeout meant elapsed time on Windows and a share of the process's CPU on Android,
which is what ADR-0001 anticipated, and **the deadline had to become wall-clock**. The fork now
does that, in commit `8b2ef85`: the handler in `third_party/flutter_qjs/cxx/ffi.cpp` reads
`std::chrono::steady_clock`, about a dozen lines. Runs 4 to 6 verify it on both emulators: the
blocked script is interrupted at 1014 to 1020 ms, the sleeper at 1005 to 1018 ms whatever its
neighbour does, and on the loaded API 35 emulator the busy loop fires at 1000 ms while the process
has used less than 1000 ms of CPU. Windows, where `clock()` was already wall time, behaves as
before.

### The memory-limit failure: the host was told `null`

On API 26 the memory-limit probe stopped the script, so **the limit was enforced**, but the host
did not learn why. Instead of `InternalError: out of memory` it got a Dart
`TypeError: type 'Null' is not a subtype of type 'Object'`. Precisely:

1. When an allocation would take the runtime past its limit, QuickJS builds an
   `InternalError("out of memory")`, and building it allocates too.
2. If the refused request was small, the headroom left under the limit cannot hold the error
   either. `JS_ThrowError2` then throws **`null`**, on purpose: its comment reads "out of memory:
   throw JS_NULL to avoid recursing". A script's own `catch (e)` sees `e === null`.
3. flutter_qjs's `evaluate` did `throw _parseJSException(ctx)`, which converted that `null` to a
   Dart `null`, and Dart turns `throw null` into the `TypeError`.

Whether probe 5 meets this depends on the allocator's size classes: API 26's jemalloc meets it
every time, API 35's allocator and Windows' happen not to. Probe 11 makes the refused request tiny
and met it on all three. It was a latent defect on every platform, which Android exposed.

In an async function it was worse. There the `null` arrives as a promise rejection, the
rejection callback's `completeError(null)` threw instead of completing, and **the awaited future
never completed**: an extension call that hit the memory limit would have hung its caller. This
was found on Windows while checking the fix, and probe 12 now covers it.

The fix, commit `2451f2f`, is a few lines in `third_party/flutter_qjs/lib/src/wrapper.dart`:
`_parseJSException` returns `InternalError: out of memory (QuickJS threw null)` for a thrown
`null` and a plain `InternalError` for any other value with no Dart equivalent, and a promise
rejected with `null` or `undefined` completes with an `InternalError` saying it may be out of
memory. A script's own `throw null` is reported as out of memory too, because nothing tells the
two apart. Lifting the limit in `JS_ThrowOutOfMemory` while the error is built, the obvious C fix,
was tried first and crashed the process.

### Known gap: host calls restart the deadline

On every platform and with either clock, a loop that calls a host function **with a string
argument** is never interrupted: 2.5 million calls in 4 s on API 26. `ffi.cpp` restarts the
deadline on every entry from Dart into QuickJS, and converting a JS string for Dart
(`jsToCString`) is one such entry, as are `jsCall` and each promise job. So the deadline bounds
each stretch between host calls, not a script. The memory limit still stops such a loop if it
allocates, but `while (true) console.log('x')` would run forever. This is the second reason for
the host-callback patch ADR-0001 already plans: the host, not each native entry, should decide
when a script's time starts and ends. Until it lands, `source_runtime` must not rely on the
deadline alone to stop a script that calls host functions. Probe 10 records the restart, so it
will show when the patch fixes it.

### Caveats

- These are x86_64 emulators, not devices. arm64, which real phones use, is compiled by the build
  but has not been run.
- The `google_apis` images keep the CPU busy after boot, especially API 35; the timings under the
  `clock()` deadline reflect that, which is itself part of the finding.
- Each timing is from a single run. The deadline figures agree across runs 4 to 6 within 20 ms.

### Why not on the development machine

The emulator there refuses to start:

```
ERROR | x86_64 emulation currently requires hardware acceleration!
CPU acceleration status: Android Emulator hypervisor driver is not installed on this machine
```

VT-x is enabled in firmware (`Win32_Processor.VirtualizationFirmwareEnabled` is `True`), but
nothing provides acceleration (`Win32_ComputerSystem.HypervisorPresent` is `False`); the
hypervisor driver is absent. `flutter doctor` still reports the Android toolchain as green, because
it checks the SDK and licences and not whether an emulator can start, so a green doctor is not
evidence that Android is runnable. Installing the driver elevated from Android Studio's SDK Tools,
or a physical phone over adb, would let the probe run locally too; CI no longer depends on either.

## Kikuyomi's ScriptEngine: probes 13 to 19

The binding is not what the app is written against. `ScriptEngine` (packages/source_runtime) is,
and `QuickJsScriptEngine` (packages/platform_adapters) implements it over the fork. Probes 13 to 19
drive that interface end to end, which can only be done in a built app, so they live here beside
the binding's own probes.

- **13, an extension through the interface.** A small extension is loaded, a method called with
  plain-data arguments, a host function awaited inside it, and the result read back as plain data.
- **14, the deadline the host arms.** `while (true) hostLog('x')`, the very loop probe 10 records
  running for ever under the old deadline. It must stop near the deadline.
- **15, a call that is not running.** An extension awaiting a host promise that never settles
  cannot be interrupted, because no JavaScript is running for the interrupt handler to stop. The
  engine bounds the future as well as the script, so the call still ends at its deadline.
- **16, the memory limit as a typed error**, and a runtime that answers again afterwards, which is
  what §3.6's pooling assumes.
- **17, a typed error** from a script that throws.
- **18, cancellation from a host call** the script itself made, reported as a cancellation rather
  than as a deadline.
- **19, cancellation from another isolate**, which is the case that matters: while a script runs,
  the isolate that started it is inside QuickJS and reaches none of its own messages.

## The extension protocol: probes 20 to 22

Everything above the engine is unit tested against a fake one, but the prelude (§3.5) is
JavaScript, and only QuickJS can say whether it runs. These three load a small extension through
`ExtensionRuntime`, with the real prelude and the real `html`, `crypto`, `log` and `storage`
bridges, and call it through `JsSourceAdapter`.

- **20, the whole prelude.** One `getPopular` that logs, builds a `URL` and reads its
  `searchParams`, parses HTML and reads an element's text and `absUrl`, hashes with SHA-256, writes
  and reads `storage`, round-trips text through `TextEncoder` and `TextDecoder`, uses `atob` and
  `btoa`, awaits a `setTimeout`, and reads `host.apiVersion` — and whose result is decoded into the
  contract's types.
- **21, a refused selector.** `:has()` throws inside the extension, which catches it and reads the
  message, as an author would.
- **22, an error's kind.** An error thrown with the SDK's shape arrives as `NotFoundException`,
  which is the whole reason nothing is thrown across the boundary.

## The LibriVox extension: probes 23 to 34

The extension the app ships (`app/assets/extensions/librivox/main.js`) is JavaScript, so nothing
under `flutter test` can run it either. These run the real file on the real engine against LibriVox
answers recorded into `qjs_probe/assets/librivox/fixtures/`, served by a bridge that refuses any URL
it has no fixture for. Never against the live site: a probe that reached the network would fail for
reasons that have nothing to do with the code, and would ask a volunteer-run site for something on
every CI run.

`qjs_probe/assets/librivox/main.js` is a copy, because a Flutter package can only bundle assets
inside itself. `app/test/librivox_extension_test.dart` fails if the two ever differ, so a stale copy
cannot quietly prove nothing.

- **23, it loads**, exports the source its manifest names, and declares exactly the optional methods
  it has, which is `filters` and nothing else.
- **24, one page of the catalogue**, decoded into `BookSummary`: the key is the book's LibriVox id,
  the cover comes out of the Internet Archive item named in `url_zip_file`, and a page shorter than
  the page size is the last one.
- **25, search with no filter set** asks by title and by author and puts the two together, because
  the API will not do both at once.
- **26, the same, the other way round**: a name no title starts with, which only the author search
  finds.
- **27, search narrowed by the source's own filter** asks once, of that field alone.
- **28, a book's details**: the HTML summary unwound into plain text with its paragraphs kept, the
  readers gathered from its sections, `English` mapped to `en`, and a status of `complete`.
- **29, its chapters**, keyed by section id, and details and chapters together costing one request
  rather than two, because the extension keeps the one document that holds both.
- **30, resolving a chapter** to the file on the Archive, with its format, its length and a file key
  that is the file's own name.
- **31, the same extension in a worker isolate**, which is the path the app really takes (§3.6),
  with `http`, `storage` and `log` proxied back to the isolate that started it. Nothing else runs
  QuickJS in a spawned isolate: the tests use a fake engine there, and every probe above it runs the
  engine in the isolate it was made in. So this is the only place that says whether the engine, its
  native library and the plain-data crossing all work where the app puts them.
- **32, nothing found.** LibriVox answers a search that matches nothing with an error object and
  status 200. That is an empty page; asked for one book by id, the same answer is `NotFound`.
- **33, the whole of one book costs one request.** Its details, its chapters and the audio of
  every one of its sections all read the same extended document, and the extension keeps the
  fetch rather than its result, so calls that overlap join the one already on its way. This is
  what made pressing play on a streamed book slow: one request per chapter, each waiting for the
  last.
- **34, the audio address has no hop in front of it that can be taken off.** LibriVox writes
  `www.archive.org` into every `listen_url`, and that host redirects to `archive.org` before the
  redirect to the node the file is really on. A player asks for a file in ranges, so that hop is
  paid on every seek rather than once; both hosts are declared in the manifest.

## Results

On Windows all thirty-four pass. Probe 14 stops at 1003 ms after about 130,000 host calls, where the
same loop under the old deadline (probe 10, still in the run) reaches its own 4000 ms bound.
Probe 19 is cancelled 449 ms after the call starts, the cancellation having been sent at 501 ms
from another isolate. Probe 20 runs the whole prelude in 103 ms. The nine in-isolate LibriVox probes take 3 to
7 ms each, which is what a source call costs once the answer is already in hand; probe 31, which
starts a worker isolate and a QuickJS runtime inside it, takes 205 ms.

Two findings from writing them, both now fixed in the code rather than here:

- **A returned JavaScript function is a live reference.** `globalThis.f = function () {}` is an
  assignment, so it is also the script's completion value, and the binding hands back a reference
  the caller has no way to free. Closing the runtime then reports a leaked reference. The engine
  now releases anything that is not plain data before returning, which is also what the interface
  promises.
- **A closure sent to an isolate captures its whole context.** `Isolate.run(() => handle.cancel())`
  written inside a probe captured the engine too, and an engine holds a `Future`, which is not
  sendable. The cancel handle is plain data; the closure around it was not.

## Next, in order

1. Measure memory per runtime and the cost of pooling several, since the runtime pool in §2.7
   assumes several per worker isolate.
2. Run the probe on an arm64 device when there is one.

How the fork is carried is decided: vendored in `third_party/flutter_qjs`, outside the pub
workspace, with every change recorded in its `README.kikuyomi.md`.

## Second half of this spike

CSS selector coverage in the Dart `html` parser: **done**, in `spikes/html_selectors/`.
20 of 28 probes correct. `:has()`, `:nth-of-type()` and `:nth-child(an+b)` raise
`UnimplementedError`, while `:empty`, `:nth-child(odd)` and `:nth-child(n)` on indented HTML
**silently match nothing**, which is the more dangerous half of the result.
