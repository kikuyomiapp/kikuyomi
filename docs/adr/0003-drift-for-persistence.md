# ADR-0003: Drift (SQLite) for persistence

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §2.5, decision 4

## Context

The library is a relational problem, not a document store. Filtering by author, narrator and
language, sorting by progress or date added, joining against many-to-many categories, and
full-text searching titles are all ordinary queries in SQL and awkward in anything else.

Two further requirements narrow the field. The architecture makes **the database the single source
of truth**, with the UI watching streams rather than holding copies, so reactive queries are
mandatory rather than a convenience. And every schema change must ship with a migration and a
migration test, so generated schema snapshots matter.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Drift** | Typed SQL; versioned migrations with generated schema snapshots for migration tests; reactive `watch()`; FTS5; background isolate execution; supports every target platform | Code generation step; more ceremony than a key-value store | **Chosen** |
| Isar | Fast; what Mangayomi uses | Has had maintenance gaps, and this is the one component whose failure loses user data | Rejected |
| sqflite | Familiar and simple | No Windows support without extra work; no reactive layer; migrations are hand-rolled | Rejected |
| Hive | Simple | Not relational; the library queries would be written by hand in Dart | Rejected |

## Decision

Drift over bundled SQLite, via `sqlite3_flutter_libs`, with the schema, migrations, repository
implementations and mappers in the `data` package.

## Consequences

**Reactive queries are what make the single-source-of-truth rule enforceable rather than
aspirational.** A finished download, a completed refresh and a saved progress update each land in
one place and every screen showing that data updates itself. No cache invalidation, no manual
refresh calls, no screens holding stale copies. This is the main reason for the choice and it
should not be given up lightly.

Bundling SQLite rather than using the platform's own copy costs binary size and buys identical
behaviour and identical FTS5 availability on all three platforms. For a database that must survive
backup and restore across platforms, identical behaviour is worth more than the megabytes.

Drift's generated schema snapshots make migration tests mechanical: every version is snapshotted,
and a test walks each upgrade path. Given that the alternative is discovering a broken migration
in the field after a user's library is already in the old shape, this is the feature that decided
it against Isar.

**The escape hatch is the repository interfaces in `domain`.** Nothing outside `data` knows Drift
exists; the rest of the app talks to repositories. Replacing the storage engine means
reimplementing those interfaces, not touching features. The one thing that would not survive is
the reactive-stream contract, which any replacement would also have to provide.
