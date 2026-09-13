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
| `flutter_qjs` 0.3.7 | Interrupt handler and memory limit both present and reachable from Dart; `IsolateQjs` gives isolate safety; `dispatch()` job loop; no extra toolchain; MIT, so forkable; keeps `source_runtime` pure Dart | Unmaintained for four years; interrupt is a fixed timeout rather than a host callback; uses `clock()`, which means CPU time on POSIX and wall time on Windows | **Provisionally chosen** |
| `quickjs_engine` 0.1.5 | Current; QuickJS-NG 0.14.0 identically on five platforms | **Bridge never installs an interrupt handler**, so a runaway script cannot be stopped; memory limit hardcoded at 64 MB; exists as a side-component of an SVG renderer | Rejected on criterion 3 |
| `quickjs` (lindeer) 1.0.1 | Pure Dart via `native_assets_cli`; Apache-2.0 | Does not support Flutter; neither non-negotiable found in source | Rejected |
| Rust `rquickjs` + `flutter_rust_bridge` | Both non-negotiables, with a true host callback; actively maintained; Mangayomi precedent | Rust toolchain on the dev machine and all three CI runners; NDK r26+, Xcode 15+; FRB generates Flutter-coupled glue, conflicting with §2.4's pure-Dart `source_runtime` | **Documented fallback** |

## Decision

Provisionally adopt `flutter_qjs`, vendored as a maintained fork, and keep the Rust `rquickjs`
route as the documented fallback.

This is **Proposed, not Accepted**. It rests on source review, not on a build. It becomes Accepted
only once a throwaway app using `flutter_qjs` builds and runs on Windows and Android against
Flutter 3.47.3, and the measurements in the spike README are recorded. If four years of Dart FFI,
NDK and Gradle drift have broken it beyond cheap repair, this ADR is superseded by one choosing
the Rust route, and §2.4 will need revisiting at the same time.

## Consequences

Choosing `flutter_qjs` means **taking ownership of a small C++ bridge**. `ffi.cpp` is the whole
surface, and two changes are already anticipated: replacing the `clock()`-based timeout with a
wall-clock deadline so the same value means the same thing on every platform, and replacing the
fixed timeout with a host-supplied callback so playback or navigation can cancel a running script.
Both are modest patches to code we would then control, which is the argument for forking rather
than depending.

What it makes easy: no new toolchain, no CI change, and `source_runtime` stays a pure-Dart plus
FFI package exactly as the package map specifies.

What it makes hard: every QuickJS security fix becomes our responsibility to pull in, and the
per-platform build matrix for the native library becomes ours to keep green.

**The escape hatch is `ScriptEngine`.** The engine sits behind that interface precisely so this
decision can be reversed. Switching to the Rust route, or to JavaScriptCore on Apple platforms if
App Store review ever demands it, means reimplementing one interface rather than touching the
extension system.
