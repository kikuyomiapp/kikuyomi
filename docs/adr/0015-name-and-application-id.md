# ADR-0015: Name and application ID

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §2.4 and §9, decision 15

## Context

The application ID and Android namespace are effectively permanent. Changing an Android
`applicationId` after release produces a different app: the Play listing, the installed package,
its data directory and its update path all change, and existing users are not upgraded but given a
second copy. The same is true in a different form on iOS, where the bundle identifier determines
the data container — Appendix A notes that a re-signed build with a changed identifier starts with
an empty one.

The intended identifier was `io.github.kikuyomi`, under a GitHub organisation of the same name.
**That organisation name was already taken.** The documented fallback was
`io.github.<username>.kikuyomi`.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **`io.github.kikuyomiapp.kikuyomi`** | Matches an organisation the project actually owns; keeps the project name in the identifier; organisation-owned rather than tied to a personal account | Slightly longer; `kikuyomiapp` is not the product name | **Chosen** |
| `io.github.<username>.kikuyomi` | The documented fallback | Ties the identifier to a personal account, which is awkward if maintenance is ever shared | Rejected |
| A different product name with a free organisation | A cleaner identifier | The name is decided and is good; renaming a project to win a namespace is the wrong trade | Rejected |

## Decision

The product is **Kikuyomi**. The application ID and Android namespace are
**`io.github.kikuyomiapp.kikuyomi`**, following the `kikuyomiapp` GitHub organisation the project
owns. This is final.

## Consequences

**The Flutter app package keeps the bare pubspec name `kikuyomi`.** Its package name feeds the
application ID and the namespace, so renaming it — for instance to `kikuyomi_app` for consistency
with the `kikuyomi_` prefix used elsewhere — would disturb identifiers that are locked. §2.4 was
amended to scope that prefix to the packages under `packages/` for this reason.

**Neither the application ID nor the bundle identifier may be hardcoded** anywhere in the source.
They are read at runtime. Appendix A explains why this is not pedantry: a re-signed iOS build may
legitimately carry a different bundle identifier, and any code that assumed the compile-time value
would look in the wrong place for its own data. The same discipline covers app-group identifiers.

The `kikuyomi://` deep-link scheme is independent of the application ID and is unaffected.

Because this is effectively irreversible, the discrepancy between the document and the Android
manifest was worth resolving explicitly rather than leaving as an inconsistency someone would
later try to "fix" in the wrong direction.
