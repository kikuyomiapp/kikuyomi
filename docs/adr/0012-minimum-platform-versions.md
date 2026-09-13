# ADR-0012: Minimum platform versions

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §2.2, decision 14

## Context

Every version supported below the current one costs testing surface and forecloses APIs. Every
version dropped excludes users. For an audiobook app the calculus is unusual in one respect: the
users most likely to be on old hardware are also the users most likely to listen on a cheap phone
kept for exactly that purpose.

The constraints that actually bind are the background-work and storage APIs, because those are
where Android changed most and where this app does its least visible but most important work.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Android 8.0 (API 26), Windows 10, iOS 17** | Covers the overwhelming majority of live devices; API 26 is where notification channels and modern background limits begin, so the code has one model rather than two | Excludes genuinely old Android devices | **Chosen** |
| Lower Android minimum (API 21) | A few percent more devices | Pre-Oreo background execution and notification models are a second implementation of the hardest subsystem | Rejected |
| Higher Android minimum (API 29+) | Scoped storage only; simpler file access | Excludes a meaningful share of the cheap-device audience | Rejected |
| Lower iOS minimum | More sideload targets | iOS is Phase 7; picking a modern floor costs nothing now | Deferred |

## Decision

Android 8.0 (API 26), Windows 10, iOS 17.

## Consequences

**API 26 is chosen for background work, not for UI.** Notification channels, the foreground-service
model and the modern background-execution limits all start there. Supporting anything earlier
would mean two code paths through the download service and the media notification, which is
precisely the area where bugs are hardest to reproduce and most damaging — a download that stops
silently, or playback that dies when the screen locks.

Storage access still needs care in the supported range. Scoped storage arrives partway through it,
so the local-files source cannot assume either model and must go through the folder-access adapter
in `platform_adapters` rather than touching paths directly.

Windows 10 rather than 11 is nearly free: Flutter supports it, and the desktop APIs used here —
SMTC, protocol registration, window state — are present in both.

iOS 17 is a cheap decision today because iOS is Phase 7 and there are no users to exclude yet. It
should be **revisited when that phase starts** rather than inherited unexamined, since the sideload
audience's device distribution is not the same as the App Store's.

These floors are a **contract with the CI matrix**: the Android job's `minSdk` and the emulator
images tested against should match this ADR, and a change to either without a change here is a
drift worth catching in review.
