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

From the roadmap in `docs/architecture.md` §8.

| Spike | Question it answers | Target platforms | Produces |
|---|---|---|---|
| `quickjs_binding/` | Which QuickJS binding meets the criteria in §3.1: Promise/async with a host-driven job loop, interrupt handler, per-runtime memory limit, builds for Android/Windows/iOS, isolate-safe, maintained? Candidates are an existing Dart FFI package or a thin Rust `rquickjs` layer via `flutter_rust_bridge`. Also: does the Dart `html` parser cover the CSS selectors real sources need? | Android, Windows, iOS | ADR on the script engine binding |
| `playback/` | Does `just_audio` + `audio_service` handle a multi-file book, custom request headers, speed, notification/SMTC controls, background playback, and audio focus? | Android, Windows | ADR on the playback stack |
| `downloads/` | Does `background_downloader` survive expiring URLs, process kill, and Android foreground-service limits? What does Windows do? | Android, Windows | ADR on the download transport |
| `m4b_chapters/` | How do we extract embedded chapter markers from M4B, and how accurate are the resulting offsets? | Android, Windows | ADR on chapter extraction |
| `ios_canary/` | Does a CI-built unsigned IPA sideload onto the iPhone, launch, and play audio in the background? | iOS | Notes appended to Appendix A |
