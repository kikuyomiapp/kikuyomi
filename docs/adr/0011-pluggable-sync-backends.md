# ADR-0011: Pluggable sync backends rather than one cloud provider

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §2.4, decision 13

## Context

Users with more than one device want their position in a book to follow them. The obvious
implementation is a hosted service, and it is the wrong one for this project.

A hosted sync service means running infrastructure, holding user accounts, and becoming a single
point of failure for a solo, part-time, open-source project with no revenue. It also makes the
project a more visible target in a content area where §7.1 already counsels caution.

The users this app is for already have somewhere to put files: a synced folder, a WebDAV server,
or an Audiobookshelf instance they run themselves. Audiobookshelf is especially relevant because
it is both a *source* and a *progress store*, so syncing to it is not a bolt-on.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Pluggable `SyncBackend`: folder, WebDAV, Audiobookshelf** | No infrastructure; users keep their data; Audiobookshelf sync is native to how those users already work | Several implementations; conflict resolution must be solved generically | **Chosen** |
| One hosted service | Best experience; simplest for users | Infrastructure, accounts, cost, liability, and a single point of failure | Rejected |
| One third-party cloud SDK | Less infrastructure than self-hosting | Ties every user to one vendor; several are awkward or unavailable on Windows | Rejected |
| No sync | Simplest | Multi-device is a real need, and progress is the thing users most hate losing | Rejected |

## Decision

A `SyncBackend` interface with several implementations — a user-chosen folder, WebDAV, and
Audiobookshelf — in the pure-Dart `sync` package. Deferred to Phase 6; the package exists now so
the dependency direction is fixed before anything is written against it.

## Consequences

**Conflict resolution has to be solved once, generically, and it is the hard part.** Two devices
listening to the same book produce two positions, and neither "last write wins" nor "furthest
position wins" is right in every case: last-write loses progress when a device syncs late, and
furthest-position defeats deliberately re-listening. The rule needs deciding before the first
backend ships, and it belongs in `sync`, not in each backend.

Sync builds on the backup format rather than inventing a wire format, which is why `sync` depends
on `backup`. That keeps one schema and one set of field-number discipline.

The folder backend is the one that costs nothing and covers most users, because it works with
whatever they already sync. It should ship first, and the others should be measured against it.

Audiobookshelf is a special case worth naming: for those users it is the authority on progress,
not a peer. Syncing to it is closer to writing through to a server than to reconciling two
replicas, and the interface must not force it into the wrong shape.

**The escape hatch is the interface itself.** If a hosted service ever becomes justifiable, it is
one more implementation rather than a redesign.
