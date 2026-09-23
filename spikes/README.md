# Spikes

Phase 0 experiments. **Everything in this directory is throwaway.** A spike exists to answer one
question on the real toolchain and produce an ADR plus recorded measurements; none of this code
graduates into `app/` or `packages/`. Production code starts in Phase 1.

Spikes are not part of the pub workspace and are not held to the quality bar in `CLAUDE.md`: no
test coverage requirement, no analyzer-clean requirement. They are held to one standard, which is
that the result must be reproducible by someone reading the spike's own README.

Each spike lives in its own directory with a `README.md` recording the question, how to run it,
what happened on each platform, and the numbers.

## Phase 0 spikes

From the roadmap in `docs/architecture.md` §8. Status as of the last commit.

| Spike | Status | Outcome |
|---|---|---|
| `quickjs_binding/` | **Done**, and kept | The fork in `third_party/flutter_qjs` passes all thirty-four probes on Windows and on API 26 and API 35 emulators in CI. On Android the deadline counted CPU time for the whole process, so the fork now uses a wall-clock one; and where the memory cap left no room for an error, the host was handed `null` and now gets "out of memory". ADR-0001, Accepted. It has outlived its throwaway purpose: `flutter test` does not build a plugin's native library, so this is where `ScriptEngine` (probes 13 to 19), the extension protocol (20 to 22) and the LibriVox extension the app ships (23 to 34, against recorded answers, the last of them in a worker isolate as the app runs it) are run on a device. |
| `html_selectors/` | **Done** | `package:html` covers what extensions need, but `:has()` is unsupported and `:empty`, `:nth-child(odd)` and `:nth-child(n)` on indented HTML **silently match nothing**. |
| `playback/` | **Windows done, Android not run** | The stack works. Two undocumented behaviours would each silently corrupt resume; both are now requirements on the `PlaybackEngine` adapter. ADR-0006. |
| `m4b_chapters/` | **Done** | Both chapter formats read in pure Dart, seek-based, ~1% of the file. No platform plugin and no ffmpeg at runtime. |
| `downloads/` | **Windows done, Android not run** | 7 of 7 pass against a local origin the probe starts itself. `progress` is a union of a 0-1 fraction and five negative sentinels, so it must never reach the UI. Foreground-service limits, process death and Doze are unobservable on Windows. |
| iOS canary | **Launches; audio not yet tried** | The CI-built IPA, sideloaded onto the iPhone, installs and launches. Adding and playing a book, and playing on with the phone locked, wait for an M4B on the phone. |

## What is blocking

**The Android emulator will not start on the development machine.** No hypervisor driver is
installed, although VT-x is enabled in firmware. This blocks the Android half of spike (b) and
most of spike (c). Spike (a) no longer depends on it: its probe runs on emulators in GitHub
Actions (`.github/workflows/android-emulator.yml`), whose Linux runners have KVM, and the same
route is open to the others where an emulator can show what they need. `flutter doctor` reports the Android toolchain as green, because it
checks the SDK and licences and not whether an emulator can run — so a green doctor is not
evidence that Android works.

The fix is the SDK Tools tab in Android Studio, which can elevate; the command-line `sdkmanager`
on this machine is a shim to a new CLI that fails to self-update. A physical Android device would
also do, and §2.2 already argues for one on the grounds that real devices kill background work in
ways emulators do not — which is exactly what spikes (b) and (c) need to observe.

