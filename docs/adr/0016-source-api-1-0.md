# ADR-0016: SourceAPI 1.0, the extension contract

- **Status:** Accepted
- **Date:** 2026-09-21
- **Relates to:** `docs/architecture.md` §3.4 to §3.7 and §4.4; ADR-0001; ADR-0013; the full
  contract is in [`docs/source-api-1.0.md`](../source-api-1.0.md)

## Context

Phase 2 begins with the contract every source extension is written against. It is the project's
one public API: once third parties ship extensions against 1.0, a mistake in it can only be undone
by 2.0 and a deprecation window (§3.7). CLAUDE.md therefore requires approval before
`packages/source_api` changes, and this record was that request. It was approved with the answers
under "Approval" below.

§3.4 sketched the contract's shape. Phase 1 then built the parts of the app the contract feeds,
which makes several details concrete:

- The §4.4 merges exist (`BookDetails` for a book's details, `IncomingChapter` for chapter sync),
  and the contract's types must map onto them without loss.
- The Timeline and the `MediaResolver` interface exist, with a resolver for local files. A source's
  media must fit the same shape: engine items are files, chapters are an overlay, and progress is
  chapter-relative (§4.5).
- Phase 0 found selectors the Dart HTML parser gets **silently** wrong
  (`spikes/html_selectors/`). Whatever the host's `html` bridge does with them is part of the
  contract.

## Options considered

The contract as a whole is not an either/or; the choices that are, and what was picked:

| Question | Options | Verdict |
|---|---|---|
| What goes into 1.0 | Everything §3.4 sketched, or only what the Phase 2 app actually implements | **Only what Phase 2 implements.** An optional method the app ignores is a trap for authors, and minor versions add methods without breaking anyone |
| How `resolveMedia` names a chapter | Chapter key alone, as sketched, or book and chapter keys | **Both keys.** A chapter key is unique only within its book (§4.4); with the key alone, authors would pack the book's id into every chapter key |
| How filter values are passed | By position, as Mihon does, or by each filter's key | **By key.** An extension update that adds or reorders filters can then never misread a saved search |
| What the `html` bridge does with selectors it gets wrong | Implement them correctly in the host now, pass them through, or refuse them | **Refuse them, loudly.** A thrown error surfaces during development; a silently empty result corrupts a library in production. Supporting them later is additive |
| Which hosts media and cover URLs may point to | Anywhere; declared domains for audio only; or declared domains for both | **Declared domains for both**, wildcards allowed, as `http.fetch` already is. The permissions screen then lists every domain the source can make the app contact. Strict is also the only starting point that can be relaxed later without breaking extensions |
| When a chapter's layout is known | Resolve every chapter when a book is added, or resolve each when it is first played | **When first played.** Resolving a whole book up front costs one call per chapter against the site's rate limits, for URLs that often expire within minutes. Until then a chapter counts as one file of its `durationMs`, marked as an estimate, which the Timeline already supports |
| Where the TypeScript SDK lives | A folder in this repository, or a repository of its own | **Its own repository**, released with the same API version as the contract |

## Decision

Adopt SourceAPI 1.0 as written in `docs/source-api-1.0.md`. In short:

1. **Required methods:** `getPopular`, `search`, `getBookDetails`, `getChapters` and
   `resolveMedia`. **Optional:** `getLatest`, `getFilters`, and `getImageRequest` for covers that
   need headers.
2. **Left to 1.x**, each arriving with the app feature that uses it:
   - `getHome` arrives with the Home feed in Phase 4.
   - `handleUrl` arrives with deep links.
   - `getSettings` and the login flow arrive in Phase 5.
   - The `ui` bridge (the in-app WebView challenge, and later a headless WebView) also arrives in Phase 5.
   - Until then, `ChallengeRequired` and `LoginRequired` are still reported. The app then offers to open the page in a browser.
3. **Plain data across the boundary**, validated against fixed limits when it arrives. A result
   that breaks one fails that call as `Parse`, and nothing of it is written.
4. **Declared domains only.** Every URL an extension fetches or hands to the app, whether a page,
   audio or a cover, must be on its manifest's `domains` list, wildcards included.
5. **The host API** is `http`, `html`, `crypto`, `storage`, `log` and `host`, as §3.5 lists, with
   the selector refusals above. `crypto` exists to read a site's own responses; the host never
   applies it to media, and the extension policy forbids any DRM-related use (§7.1).
6. **The Dart mirror** in `kikuyomi_source_api` holds the same types, the sealed `SourceException`
   family, the `ContentSource` interface and shared decoders. Both the JavaScript adapter and
   built-in sources implement `ContentSource`, Local first.
7. **The TypeScript SDK** (typings, the build and test CLI, signing) lives in its own repository.
   It mirrors this contract and is released under the same API version.

## Consequences

- **What this makes easy:**
  - Authors write against a small, fully typed surface. Every result is checked before it reaches the library.
  - The Phase 1 player, Timeline, progress, bookmarks, listened state, sleep timer and backups work unchanged for books from extensions.
  - Only the resolver that turns a chapter into playable files is new.
- **What this makes hard:**
  - Sites that need a login or a browser check can't be fully served until 1.x. Neither can sites that need selectors the host refuses.
  - The first of those is deliberate: the WebView flow is Phase 5 work. The second is a known cost, recorded in the spike.
  - A site that moves its audio or images to an undeclared host stops working until its extension declares the new domain. The app must then say so plainly.
  - Two repositories can drift apart: a contract change here needs a matching SDK release.
- **What has to stay true:**
  - Minor versions only add.
  - Each version of `source_api` has an SDK release with the same API version.
  - The contract test suite (§3.11) runs every extension against these limits before release.
- **The escape hatch** is `ContentSource`. A source that cannot live within the contract can be written natively, as the built-in sources are, without changing the contract for anyone else.

## Approval

Approved on 2026-09-21, with these answers to the questions the proposal left open:

1. **Scope:** 1.0 as proposed. The Home feed, link handling, source settings, login and the
   WebView bridge are left to 1.x.
2. **URLs:** audio and cover URLs must be on the extension's declared domains, like its own
   requests.
3. **SDK:** in a repository of its own rather than a folder here.
4. **QuickJS binding:** carry on with the patched `flutter_qjs` fork (ADR-0001). The first task of
   Phase 2 runs its probe on an Android emulator in CI, because Android is the one primary target
   it has not been proven on. The binding is switched to the Rust route only if that fails.
   ADR-0001 stays Proposed until the probe passes.

The extensions that ship with the app, from the official repository, are LibriVox and the
Internet Archive's public-domain collections, as ADR-0013 and §3.10 set out.
