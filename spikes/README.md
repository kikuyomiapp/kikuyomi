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
| `quickjs_binding/` | **Windows done, Android blocked** | `flutter_qjs` does not run on Dart 3.13 as published, but three lines fix it and all six probes then pass, including an interrupt and an enforced memory cap. ADR-0001, still Proposed. |
| `html_selectors/` | **Done** | `package:html` covers what extensions need, but `:has()` is unsupported and `:empty`, `:nth-child(odd)` and `:nth-child(n)` on indented HTML **silently match nothing**. |
| `playback/` | **Windows done, Android not run** | The stack works. Two undocumented behaviours would each silently corrupt resume; both are now requirements on the `PlaybackEngine` adapter. ADR-0006. |
| `m4b_chapters/` | **Done** | Both chapter formats read in pure Dart, seek-based, ~1% of the file. No platform plugin and no ffmpeg at runtime. |
| downloads | **Not started** | Spike (c). Its interesting cases — foreground-service limits, process kill, expiring URLs — are mostly Android. |
| iOS canary | **Blocked on hardware** | CI produces the unsigned IPA. Sideloading it needs the physical iPhone. |

## What is blocking

**The Android emulator will not start on the development machine.** No hypervisor driver is
installed, although VT-x is enabled in firmware. This blocks the Android half of spikes (a) and
(b) and most of spike (c). `flutter doctor` reports the Android toolchain as green, because it
checks the SDK and licences and not whether an emulator can run — so a green doctor is not
evidence that Android works.

The fix is the SDK Tools tab in Android Studio, which can elevate; the command-line `sdkmanager`
on this machine is a shim to a new CLI that fails to self-update. A physical Android device would
also do, and §2.2 already argues for one on the grounds that real devices kill background work in
ways emulators do not — which is exactly what spikes (b) and (c) need to observe.

