# ADR-0006: just_audio, audio_service and audio_session behind a PlaybackEngine interface

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §6, decision 7; spike (b) in `spikes/playback/`

## Context

Playback is the product. Everything else — library, browsing, downloads — exists to get audio
playing and to remember where the user got to. The stack has to deliver background playback,
lock-screen and notification controls, media keys and SMTC on desktop, audio focus and
interruption handling, variable speed, and position reporting accurate enough to resume from.

It also has to do this on three platforms with three completely different native backends:
ExoPlayer on Android, AVPlayer on iOS, and mpv on Windows.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **`just_audio` + `audio_service` + `audio_session`** | The mature, conventional Flutter audio stack; `audio_service` gives background playback and system controls; `audio_session` handles focus and interruptions; Windows via `just_audio_media_kit` | Windows support is a separate package over a different engine, so behaviour diverges | **Chosen** |
| `media_kit` everywhere | One engine on every platform, so identical behaviour | Weaker background and lock-screen integration on mobile, which is the half that matters most | Rejected |
| Per-platform native players | Best fidelity | Three implementations of the hardest subsystem | Rejected |

## Decision

`just_audio` for playback, `audio_service` for background operation and system controls, and
`audio_session` for focus and interruptions — all behind a **`PlaybackEngine` interface** in the
`playback` package, so the coordinator is testable against a fake engine and a controllable clock.

## Consequences

The interface is not decoration. Spike (b) measured the Windows backend and found two behaviours
that would each silently corrupt resume, and both must be corrected inside the adapter:

1. **`seek(position, index:)` discards the position** when it crosses to a different item.
   Asking for "index 1, offset 1500 ms" yields 0 ms. It does not throw. The adapter must use
   `initialIndex`/`initialPosition` on load, or a two-step seek when the queue is already loaded.
2. **`position` resets to zero on completion.** The obvious progress store — listen to
   `positionStream`, save what arrives — writes 0 at the end of every file. Progress must never be
   written while the state is `completed`.

Neither is documented; both were found by measurement. That is the strongest possible argument for
the interface: without it these workarounds would be scattered through feature code, and the
Android backend, which is a different engine entirely, may need a different set.

**Nothing measured on Windows transfers to Android**, because `just_audio` uses ExoPlayer there.
The same probe must be run on Android before the playback stack can be considered proven, and
until then the Android column of this decision rests on the package's reputation rather than on
evidence.

What works on Windows and is unlikely to regress: exact duration probing, multi-file playlists
advancing across boundaries unattended, 2x speed, and position holding correctly across pause.

**The escape hatch is `PlaybackEngine` itself.** Swapping to `media_kit` everywhere, or to a
native implementation on one platform, means one new implementation of that interface. The
coordinator, the Timeline, the progress rules and the sleep timer are all engine-agnostic and
tested against a fake.
