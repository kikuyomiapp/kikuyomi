# ADR-0016: SourceAPI 1.0, the extension contract

- **Status:** Proposed
- **Date:** 2026-09-21
- **Relates to:** `docs/architecture.md` §3.4 to §3.7 and §4.4; ADR-0001; ADR-0013; the full
  contract is in [`docs/source-api-1.0.md`](../source-api-1.0.md)

## Context

Phase 2 begins with the contract every source extension is written against. It is the project's
one public API: once third parties ship extensions against 1.0, a mistake in it can only be undone
by 2.0 and a deprecation window (§3.7). CLAUDE.md therefore requires approval before
`packages/source_api` changes, and this record is that request.

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
| Which hosts media and cover URLs may point to | Anywhere, or only the manifest's `domains` | **Only the manifest's domains**, wildcards allowed, as `http.fetch` already is. The permissions screen then lists every domain the source can make the app contact |
| When a chapter's layout is known | Resolve every chapter when a book is added, or resolve each when it is first played | **When first played.** Resolving a whole book up front costs one call per chapter against the site's rate limits, for URLs that often expire within minutes. Until then a chapter counts as one file of its `durationMs`, marked as an estimate, which the Timeline already supports |

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
4. **The host API** is `http`, `html`, `crypto`, `storage`, `log` and `host`, as §3.5 lists, with
   the selector refusals above. `crypto` exists to read a site's own responses; the host never
   applies it to media, and the extension policy forbids any DRM-related use (§7.1).
5. **The Dart mirror** in `kikuyomi_source_api` holds the same types, the sealed `SourceException`
   family, the `ContentSource` interface and shared decoders. Both the JavaScript adapter and
   built-in sources implement `ContentSource`, Local first.

## Consequences

- **What this makes easy:**
  - Authors write against a small, fully typed surface. Every result is checked before it reaches the library.
  - The Phase 1 player, Timeline, progress, bookmarks, sleep timer and backups work unchanged for books from extensions.
  - Only the resolver that turns a chapter into playable files is new.
- **What this makes hard:**
  - Sites that need a login or a browser check can't be fully served until 1.x. Neither can sites that need selectors the host refuses.
  - The first of those is deliberate: the WebView flow is Phase 5 work. The second is a known cost, recorded in the spike.
- **What has to stay true:**
  - Minor versions only add.
  - Every change to `source_api` comes with the matching SDK typings and decoder limits.
  - The contract test suite (§3.11) runs every extension against these limits before release.
- **The escape hatch** is `ContentSource`. A source that cannot live within the contract can be written natively, as the built-in sources are, without changing the contract for anyone else.

## Open questions for approval

1. **The 1.0 scope** above, and what is left to 1.x.
2. **Media and cover URLs held to the manifest's domains.** Recommended.
3. **Where the TypeScript SDK lives.** Recommended: an `sdk/` folder in this repository. The contract and its typings then change in the same commit, with the SDK published to npm with the first public release. The alternative is its own repository from the start.
4. **The QuickJS binding** (ADR-0001, still Proposed), which Phase 2 builds on next. Recommended: carry on with the patched `flutter_qjs` fork.
   - It passed every Phase 0 probe on Windows, it needs no toolchain, and it keeps `source_runtime` pure Dart plus FFI, as §2.4 requires.
   - rustup is now installed for `smtc_windows`, which removes one cost of the Rust `rquickjs` route. Its larger cost remains: `flutter_rust_bridge` generates Flutter-coupled glue, which conflicts with §2.4.
   - Android is still unproven for either option. The `ScriptEngine` interface remains the escape hatch if the fork fails there.
