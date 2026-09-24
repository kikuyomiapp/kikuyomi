# ADR-0013: Built-in native sources, and an official repository of public-domain catalogues

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §3.2 and §7.1, decision 3

## Context

An extension-based app with no extensions installed is an empty shell. The first-run experience
would be a browse screen with nothing in it and an instruction to go and find a repository
somewhere, which is both a poor introduction and, given §7.1, an inappropriate one: the app must
never point users at third-party repositories.

There is also a design question underneath. If built-in sources were special-cased — a "local
files" mode alongside a separate "extensions" mode — the app would have two content pipelines, two
sets of screens, and two places for every bug.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Built-in native sources implementing the same contract, plus an official repository of public-domain catalogues** | Useful with nothing installed; one pipeline; the contract is proven by first-party use | An official repository is a thing to maintain and to be answerable for | **Chosen** |
| No built-in sources | Nothing to maintain | Empty on first run; the app is not a player until a user finds an extension | Rejected |
| Built-in sources as a special path | Simpler individually | Two pipelines and two sets of screens forever | Rejected |
| No official repository | Nothing to be answerable for | Leaves users to search elsewhere, which §7.1 forbids the app from encouraging | Rejected |

## Decision

**Local files, Audiobookshelf and OPDS are built in as native sources**, implementing the same
`ContentSource` contract as extensions and indistinguishable from them to the rest of the app.
An **official repository** offers a small number of extensions for public-domain and openly
licensed catalogues — LibriVox and Internet Archive public domain.

## Consequences

Built-in sources being ordinary sources is the most valuable part. `sources_builtin` is a
first-party consumer of `source_api`, which means the contract gets exercised by code we control
before any third party depends on it. A contract that is awkward to implement shows up here first,
and it can still be changed at that point.

The Local source is promoted to a **first-class feature**, not a fallback. It makes the app
genuinely useful with nothing installed and no network, which is also the Phase 1 milestone: usable
daily on a PC and an Android device before the extension system exists at all.

Maintaining even two extensions means feeling the SDK's rough edges directly and continuously,
which is the best available defence against shipping a contract nobody else can implement.
