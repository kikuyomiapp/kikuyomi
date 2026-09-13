# ADR-0007: background_downloader as the download transport

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §5, decision 8

## Context

Downloading an audiobook is not downloading a file. The unit is a book of many large files, often
hundreds of megabytes each, that must survive the app being backgrounded, the process being
killed, and the network changing. Each platform enforces this differently: Android wants a
foreground service and will kill background work aggressively, iOS wants a background
`URLSession` and will not run app code while suspended at all, and Windows simply expects the
transfer to continue while the window is closed.

A second problem shapes the design more than the transport does. **Many sources hand out URLs that
expire**, so a URL captured when the user queued a book is frequently dead by the time the
download starts. Resolution has to happen just in time, not at queue time.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **`background_downloader`** | Real background transfers on Android and iOS; desktop support; pause and resume; progress reporting; one API over three native mechanisms | Another dependency in a critical path; iOS cannot run app code while suspended, which no package can fix | **Chosen** |
| Custom per-platform implementations | Full control | Reimplements foreground services and background `URLSession` by hand, three times | Rejected |
| Plain `http`/`dio` in an isolate | Simple; no platform coupling | Dies when the app is backgrounded on mobile, which is when downloads matter most | Rejected |

## Decision

`background_downloader` as the transport, **behind a transport interface**, with the queue,
scheduler, state machine and storage accounting living in the pure-Dart `downloads` package.

## Consequences

The division of labour is the point. The **queue is ours** — database-backed, so it survives a
process kill and can be inspected, reordered and resumed. The **transport is theirs** — the part
that must talk to `WorkManager` and `URLSession`. Keeping the state machine on our side of the
line means the interesting logic is pure Dart and unit-testable, and the untestable platform part
is as thin as it can be.

Queue items are **physical files, not chapters**, matching the engine's model. A chapter spanning
three files produces three queue entries, and a single M4B produces one, without either case being
special.

**Expiring URLs force just-in-time resolution.** A queued item stores what it needs to re-resolve
rather than a URL, and resolution happens immediately before the transfer starts. On iOS this
collides with a platform limit that no library can remove: extension code cannot run while the app
is suspended, so a queued item whose URL expired may only continue when the app is next opened.
The UI has to be honest about that rather than showing a stalled progress bar.

**The escape hatch is the transport interface.** If `background_downloader` proves unequal to the
foreground-service or expiry cases, replacing it means one new transport implementation while the
queue, retry policy, per-source concurrency limits and storage accounting stay put. Spike (c) is
what tests those cases, and it has not run yet.
