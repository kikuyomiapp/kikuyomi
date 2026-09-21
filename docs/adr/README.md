# Architecture Decision Records

Each ADR records one decision: the context that forced it, the options considered, what was
chosen, and what that choice costs. ADRs are append-only history. When a decision changes, write
a new ADR that supersedes the old one and mark the old one `Superseded by ADR-NNNN`; do not
rewrite it.

`docs/architecture.md` remains the overall design. Section 9 of that document lists the fifteen
decisions approved for Phase 0; each of those gets an ADR here so the reasoning survives
independently of the proposal it came from.

## Conventions

- Filename: `NNNN-short-kebab-title.md`, four-digit sequence starting at `0001`.
- Copy `0000-template.md` to start a new one.
- Status is one of `Proposed`, `Accepted`, `Superseded by ADR-NNNN`, or `Rejected`.
- Keep it short. If it runs past two pages, the decision is probably two decisions.

## Index

| ADR | Title | Decision | Status |
|---|---|---|---|
| [0001](0001-script-engine-binding.md) | QuickJS binding for the extension runtime | 2 | Proposed |
| [0002](0002-flutter-as-the-application-framework.md) | Flutter as the application framework | 1 | Accepted |
| [0003](0003-drift-for-persistence.md) | Drift (SQLite) for persistence | 4 | Accepted |
| [0004](0004-riverpod-for-state-and-dependency-injection.md) | Riverpod for state and dependency injection | 5 | Accepted |
| [0005](0005-go-router-for-navigation.md) | go_router for navigation | 6 | Accepted |
| [0006](0006-playback-stack.md) | Playback stack behind a PlaybackEngine interface | 7 | Accepted |
| [0007](0007-background-downloader-as-transport.md) | background_downloader as the download transport | 8 | Accepted |
| [0008](0008-gzipped-protobuf-backups.md) | Gzipped protobuf for backups | 9 | Accepted |
| [0009](0009-categories-and-collections.md) | Categories are manual, collections are rule-based | 10 | Accepted |
| [0010](0010-sideload-first-distribution.md) | Sideload-first distribution | 11 | Accepted |
| [0011](0011-pluggable-sync-backends.md) | Pluggable sync backends | 13 | Accepted |
| [0012](0012-minimum-platform-versions.md) | Minimum platform versions | 14 | Accepted |
| [0013](0013-built-in-sources-and-the-official-repository.md) | Built-in native sources and the official repository | 3 | Accepted |
| [0014](0014-apache-2-0-license.md) | Apache-2.0 licence | 12 | Accepted |
| [0015](0015-name-and-application-id.md) | Name and application ID | 15 | Accepted |
| [0016](0016-source-api-1-0.md) | SourceAPI 1.0, the extension contract | — | Proposed |

Every decision in §9 of `docs/architecture.md` now has an ADR. ADR-0001 awaits an Android run,
which is blocked on the emulator hypervisor driver. ADR-0016 is the first decision made after
Phase 0, not one of §9's; it awaits approval before `packages/source_api` is written.
