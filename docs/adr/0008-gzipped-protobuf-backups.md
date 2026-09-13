# ADR-0008: Gzipped protobuf for backups, written automatically to a user-chosen folder

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §2.4 and Appendix A, decision 9

## Context

Backups exist here for a sharper reason than usual. **Sideloaded iOS builds lose their data
container when re-signed** under a different account or tool, because the bundle identifier
changes and the app gets a new, empty container. On a free Apple ID that re-signing happens every
seven days. A user's library, progress and bookmarks cannot depend on the container surviving.

That reframes backup from a feature users opt into after losing something, to a mechanism that has
to run automatically and restore cleanly on a fresh install. The format must therefore be readable
by a *future* version of the app, and by an *older* one, because a user restoring onto a
re-signed build may not have the same version they backed up from.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Gzipped protobuf** | Compact; schema-evolvable through field-number discipline; unknown fields survive a round trip; what Mihon settled on for the same reasons | Not human-readable; needs a generation step | **Chosen** |
| Gzipped JSON | Human-readable and debuggable | Larger; no field-number discipline, so forward compatibility is convention rather than structure | Rejected |
| SQLite file copy | Trivial to produce | Couples the backup to the exact schema version; a newer database will not open on an older build | Rejected |
| Per-entity CSV | Inspectable | No nesting, no evolution story | Rejected |

## Decision

Gzipped protobuf, produced automatically to a user-chosen folder, with selective restore and
retention. The schema, export/import and restore planner live in the pure-Dart `backup` package.

## Consequences

**Field numbers are append-only, permanently.** A number that has been shipped is never reused for
a different meaning and never renumbered, and a removed field's number is retired rather than
recycled. This is the entire forward-compatibility story: an older build reading a newer backup
skips fields it does not know instead of failing, and a newer build reading an older one gets
defaults. Breaking this rule silently corrupts restores, and it will not be caught by a test that
only round-trips the current version.

Writing to a **user-chosen folder** rather than an app-private location is what makes the iOS case
work at all, and it happens to make the desktop case pleasant: the folder can be inside whatever
the user already syncs. It also means the backup outlives an uninstall on every platform, which is
the stated Phase 1 milestone — an uninstall-reinstall loop must lose nothing.

Automatic rather than manual is a deliberate reduction in user agency. A backup feature that
requires remembering to press a button protects the users who least need protecting.

Being a pure-Dart package, the format is testable without a device, and a round-trip test across
schema versions is cheap enough to run on every commit.

**The escape hatch is that the backup format is independent of the storage engine.** It is defined
in terms of domain entities, not tables, so a database change does not invalidate old backups, and
a format change is a new protobuf message rather than a migration.
