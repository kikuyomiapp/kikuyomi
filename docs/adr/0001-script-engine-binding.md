# ADR-0001: QuickJS binding for the extension runtime

- **Status:** Proposed
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §3.1 and §3.6, decision 2; spike (a) in `spikes/quickjs_binding/`

## Context

Every source extension the project will ever run executes inside this binding, so it is the single
most consequential dependency in the codebase. §3.1 settled the engine (QuickJS) and left the Dart
binding to be chosen in Phase 0 against seven criteria, of which two are not negotiable: the host
must be able to **interrupt a runaway script**, and it must be able to impose a **per-runtime
memory limit**. Extension code is untrusted; without both, a single bad extension hangs or
exhausts the app with no host-side recovery.

Four routes were evaluated: `flutter_qjs`, `quickjs_engine`, `quickjs` (lindeer), and a Rust
`rquickjs` layer behind `flutter_rust_bridge`. Package documentation proved unreliable, so each
candidate's C bridge and Dart FFI layer were read directly. The source review contradicted the
documentation review, and the full evidence is in the spike README.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| `flutter_qjs` 0.3.7 | Interrupt handler and memory limit both present, and **measured working on Windows**; `IsolateQjs` gives isolate safety; `dispatch()` job loop; no extra toolchain; MIT, so forkable; keeps `source_runtime` pure Dart | Unmaintained for four years, and **does not run on Dart 3.13 as published**; interrupt is a fixed timeout rather than a host callback; uses `clock()`, which means CPU time on POSIX and wall time on Windows | **Chosen, conditional on Android** |
| `quickjs_engine` 0.1.5 | Current; QuickJS-NG 0.14.0 identically on five platforms | **Bridge never installs an interrupt handler**, so a runaway script cannot be stopped; memory limit hardcoded at 64 MB; exists as a side-component of an SVG renderer | Rejected on criterion 3 |
| `quickjs` (lindeer) 1.0.1 | Pure Dart via `native_assets_cli`; Apache-2.0 | Does not support Flutter; neither non-negotiable found in source | Rejected |
| Rust `rquickjs` + `flutter_rust_bridge` | Both non-negotiables, with a true host callback; actively maintained; Mangayomi precedent | Rust toolchain on the dev machine and all three CI runners; NDK r26+, Xcode 15+; FRB generates Flutter-coupled glue, conflicting with §2.4's pure-Dart `source_runtime` | **Documented fallback** |

## Decision

Provisionally adopt `flutter_qjs`, vendored as a maintained fork, and keep the Rust `rquickjs`
route as the documented fallback.

**The fork is mandatory, not optional.** As published, 0.3.7 does not run on Dart 3.13 at all:
every call fails with `Pointer.fromFunction cannot be called dynamically`, because the call site
lets the FFI type argument be inferred and modern Dart requires it to be explicit. Three lines fix
it, recorded as `flutter_qjs-dart313.patch` in the spike. With the patch applied, all six probes
pass on Windows, including an infinite loop interrupted 12 ms past its 1000 ms deadline, a 1 MB
memory cap enforced, and a runtime that remains usable after being interrupted.

This stays **Proposed** until the same probe passes on Android, which is the other primary target
and the one where `clock()` means CPU time rather than wall time. If Android fails in a way three
lines cannot fix, this ADR is superseded by one choosing the Rust route, and §2.4 will need
revisiting at the same time.

## Consequences

Choosing `flutter_qjs` means **taking ownership of a small C++ bridge and its Dart layer**.
`ffi.cpp` and `ffi.dart` are the whole surface, and three changes are anticipated: the Dart 3.13
fix that is already written and proven, replacing the `clock()`-based timeout with a wall-clock
deadline so one value means one thing everywhere, and replacing the fixed timeout with a
host-supplied callback so playback or navigation can cancel a running script. All three are modest
patches to code we would then control, which is the argument for forking rather than depending.

That the first of those took three lines and produced a fully passing probe is the strongest
evidence for this option. The package is not rotten; it is merely unattended.

What it makes easy: no new toolchain, no CI change, and `source_runtime` stays a pure-Dart plus
FFI package exactly as the package map specifies.

What it makes hard: every QuickJS security fix becomes our responsibility to pull in, and the
per-platform build matrix for the native library becomes ours to keep green.

**The escape hatch is `ScriptEngine`.** The engine sits behind that interface precisely so this
decision can be reversed. Switching to the Rust route, or to JavaScriptCore on Apple platforms if
App Store review ever demands it, means reimplementing one interface rather than touching the
extension system.
