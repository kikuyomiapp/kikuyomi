# SourceAPI 1.0: the extension contract

**Status: accepted** ([ADR-0016](adr/0016-source-api-1-0.md)), not yet implemented. The
TypeScript SDK that extension authors install lives in a repository of its own; it mirrors this
document and is released under the same API version.

This is the contract between the app and a source extension. It is written in TypeScript because
that is what extension authors write; the Dart package `kikuyomi_source_api` mirrors it one to
one. It builds on the sketch in `docs/architecture.md` §3.4, and the places where it departs from
that sketch are listed at the end.

## Ground rules

- **Plain data only** crosses between an extension and the app: objects, arrays, strings, finite
  numbers, booleans and `null`. No classes, functions, `Date`s, `Map`s or `undefined` inside
  arrays. Byte bodies cross only through the `http` bridge.
- **Times** are epoch milliseconds, UTC. **Durations and positions** are milliseconds. Both are
  integers.
- **Keys** are opaque strings the source chooses. They must stay stable across extension updates,
  because the app identifies a book by `(source, bookKey)`, a chapter by `(book, chapterKey)` and
  a file by `(book, fileKey)` (§4.4). Use the site's own ids or paths, never titles, and never
  URLs that carry tokens or expiry.
- **Any method may return a value or a Promise of it.** The app awaits either.
- **Everything is validated** when it reaches the app (see Limits). A result that breaks a rule
  fails that one call with a `Parse` error. It is never partly written to the library.

## The extension module

The SDK bundles an extension into one ES2020 file (§3.3). Its default export names the sources the
manifest declares:

```ts
export interface Extension {
  /** One entry per source in the manifest, under the manifest's source key. */
  sources: Record<string, Source>
}
```

## Sources

```ts
export interface Source {
  // Discovery
  getPopular(page: number): Promise<PageResult<BookSummary>>
  getLatest?(page: number): Promise<PageResult<BookSummary>>
  search(query: SearchQuery, page: number): Promise<PageResult<BookSummary>>
  getFilters?(): Filter[] | Promise<Filter[]>

  // Content
  getBookDetails(bookKey: string): Promise<BookDetails>
  getChapters(bookKey: string): Promise<ChapterInfo[]>
  resolveMedia(chapter: ChapterRef, ctx: ResolveContext): Promise<MediaResolution>

  // Optional
  /** Headers or cookies a cover image needs. Without it, covers are fetched plainly. */
  getImageRequest?(url: string): Promise<HttpRequest>
}

/** Pages are numbered from 1. */
export interface PageResult<T> {
  items: T[]
  hasNextPage: boolean
}
```

### Books

```ts
export interface BookSummary {
  key: string
  title: string
  coverUrl?: string
  authors?: string[]
  narrators?: string[]
  durationMs?: number
}

export interface BookDetails {
  key: string
  title: string
  subtitle?: string
  authors: string[]            // in credit order
  narrators: string[]          // in credit order
  series?: { name: string; index?: number }   // 2.5 for a novella between books two and three
  description?: string         // plain text; line breaks kept
  coverUrl?: string
  genres: string[]
  language?: string            // a BCP 47 tag, such as "en" or "pt-BR"
  publisher?: string
  publishedDate?: string       // as the source gives it: "1851", "1851-10", "1851-10-18"
  isbn?: string
  abridged?: boolean
  totalDurationMs?: number
  status: 'complete' | 'ongoing' | 'unknown'
  contentRating?: 'everyone' | 'mature' | 'adult'
  webUrl?: string              // the book's page on the site, for "open in browser"
}
```

### Chapters

```ts
/** getChapters returns chapters in listening order; the array's order is the book's order. */
export interface ChapterInfo {
  key: string
  title: string
  durationMs?: number          // give it whenever it is known: see "Before a chapter is resolved"
  publishedAt?: number         // epoch ms, for serials that release chapters over time
  group?: string               // a part or volume heading, such as "Part One"
}

export interface ChapterRef {
  bookKey: string
  chapterKey: string
}
```

### Media

```ts
export interface ResolveContext {
  purpose: 'stream' | 'download'
  network: 'wifi' | 'cellular' | 'unknown'
}

export interface MediaResolution {
  segments: MediaSegment[]     // played in order, they form this chapter
  expiresAt?: number           // epoch ms; the app resolves again after this
}

export interface MediaSegment {
  /** The physical file's stable id within the book. Chapters that share a file share its key. */
  fileKey: string
  request: HttpRequest
  format?: 'mp3' | 'm4a' | 'm4b' | 'aac' | 'flac' | 'ogg' | 'opus' | 'hls' | 'unknown'
  /** The part of the file that belongs to this chapter. Absent means the whole file. */
  range?: { startMs: number; endMs?: number }
  /** The whole file's length and size, when known. */
  durationMs?: number
  sizeBytes?: number
  /** Other qualities of the same file. `request` is the default. */
  variants?: { label: string; bitrateKbps?: number; request: HttpRequest }[]
}

export interface HttpRequest {
  url: string
  method?: 'GET' | 'POST'
  headers?: Record<string, string>
  body?: string
}
```

One contract covers every audiobook layout (§3.4): an M4B with thirty chapters is thirty chapters
resolving to one `fileKey` with different ranges, and the download engine fetches that file once.
A chapter split over three files resolves to three segments. A source that only has "the book
file" returns one chapter, and the app presents the file's embedded markers as chapters after
probing it (§4.5).

**Before a chapter is resolved** the app knows its layout only from `ChapterInfo`. It treats an
unresolved chapter as one file of `durationMs`, marked as an estimate, so the whole book can be
shown, scrubbed and resumed before every chapter has been resolved. The layout the first
resolution returns is stored (`chapter_segment`, §4.3) and replaces the estimate. The URLs are
never stored, except in a download task's short-lived request snapshot (§5.2). A chapter without
`durationMs` still plays, but the book's total and the chapters after it are unknown until it has
been resolved.

### Search and filters

```ts
export interface SearchQuery {
  text: string                 // may be empty when only filters are set
  filters: FilterValues        // only the filters the user changed from their defaults
}

export type Filter =
  | { kind: 'header'; label: string }
  | { kind: 'separator' }
  | { kind: 'text'; key: string; label: string; default?: string }
  | { kind: 'checkbox'; key: string; label: string; default?: boolean }
  | { kind: 'tristate'; key: string; label: string; default?: TriState }
  | { kind: 'select'; key: string; label: string; options: Option[]; default?: string }
  | { kind: 'sort'; key: string; label: string; options: Option[]; default?: SortValue }
  | { kind: 'group'; label: string; filters: Filter[] }   // one level deep

export type TriState = 'ignore' | 'include' | 'exclude'
export interface Option { value: string; label: string }
export interface SortValue { value: string; ascending: boolean }

/** Keyed by each filter's `key`. */
export type FilterValues = Record<string, string | boolean | TriState | SortValue>
```

The kinds are Mihon's (§3.4), but values are keyed by name rather than by position, so an
extension update that adds or reorders filters never misreads a saved search.

## Errors

An extension reports failure by throwing one of the SDK's error classes. The app reacts to each
kind rather than just showing its message (§3.4):

| Kind | Fields | What the app does |
|---|---|---|
| `ChallengeRequired` | `url` | 1.0: tells the user the site wants a check in a browser, with an "open in browser" action. The in-app WebView flow arrives with API 1.x (Phase 5) |
| `LoginRequired` | | 1.0: tells the user the source needs a login the app cannot offer yet. Login arrives with settings in API 1.x |
| `RateLimited` | `retryAfterMs?` | Backs off, and pauses that source's download queue |
| `NotFound` | | Marks the book or chapter unavailable at the source |
| `SourceOutdated` | | Suggests updating the extension |
| `Network` | | Retries with backoff; counts toward the extension's health |
| `Parse` | | Retries once; counts toward the extension's health |

Anything else thrown, including a plain `Error`, is treated as `Parse`. A kind added by a later
minor version is treated as `Parse` by an older app, so adding kinds stays additive.

## The host API

What an extension can do is exactly this list (§3.5). It is reached through the global
`kikuyomi` object, which the SDK re-exports with types. Every call except `host` is asynchronous.

```ts
// http: only to the manifest's domains; one cookie jar per extension; the app sets User-Agent.
http.fetch(request: HttpRequest & { responseType?: 'text' | 'json' | 'bytes' })
  : Promise<{ status: number; url: string; headers: Record<string, string>;
              body: string | unknown | ArrayBuffer }>
// Any status is returned, including 404 and 500. Only a failure to connect throws Network.

// html: parsed by the app; page scripts never run.
html.parse(text: string, baseUrl?: string): Promise<HtmlDocument>
interface HtmlElement {
  select(css: string): HtmlElement[]
  selectFirst(css: string): HtmlElement | null
  text(): string                           // whitespace collapsed
  attr(name: string): string | null
  absUrl(attrName: string): string | null  // resolved against baseUrl
  html(): string
}
interface HtmlDocument extends HtmlElement {}

// crypto: for reading a site's own responses. Never for media, and never for DRM.
crypto.hash(alg: 'md5' | 'sha1' | 'sha256' | 'sha512', data: string | ArrayBuffer): Promise<string>
crypto.hmac(alg: 'sha1' | 'sha256' | 'sha512', key: string | ArrayBuffer,
            data: string | ArrayBuffer): Promise<string>
crypto.base64Encode(data: string | ArrayBuffer): Promise<string>
crypto.base64Decode(text: string): Promise<ArrayBuffer>
crypto.aesDecrypt(options: { mode: 'cbc' | 'gcm' | 'ctr'; key: ArrayBuffer; iv: ArrayBuffer;
                             data: ArrayBuffer }): Promise<ArrayBuffer>

// storage: this extension's own small key-value store.
storage.get(key: string): Promise<string | null>
storage.set(key: string, value: string): Promise<void>
storage.remove(key: string): Promise<void>

// log: into the in-app extension console; rate-limited.
log.debug(message: string); log.info(message: string)
log.warn(message: string); log.error(message: string)

// host: synchronous and read-only.
host.apiVersion: string      // "1.0"
host.appVersion: string
host.has(feature: string): boolean
```

**Selectors.** The app parses HTML with Dart's `html` package, and Phase 0 found selectors it gets
silently wrong (`spikes/html_selectors/`). In 1.0, `select` and `selectFirst` **throw** for
`:has()`, `:nth-child()`, `:nth-last-child()`, `:nth-of-type()`, `:only-of-type` and `:empty`,
rather than returning a wrong answer. Everything else in the spike's "what works" list is
supported. A later minor version may add these once the app implements them correctly, which is
additive.

**The prelude** that ships inside the app gives extensions `setTimeout`, `clearTimeout`,
`TextEncoder`, `TextDecoder`, `URL`, `URLSearchParams`, `atob` and `btoa`. There is no global
`fetch`; network access is `http.fetch` only.

## Limits

The app enforces these when an extension's result arrives, and fails the call with `Parse` when
one is broken. They are generous for honest sources and exist to bound a broken or hostile one.

| What | Limit |
|---|---|
| Any key | 1 to 512 characters |
| A title, label, name or other short text | 1,000 characters |
| A description | 20,000 characters |
| Results in one page | 200 |
| Chapters in one book | 20,000 |
| Segments in one chapter | 2,000 |
| Variants of one segment | 10 |
| Filters, counting those inside groups | 100 |
| Header name and value | 256 and 8,192 characters; no `Host`, `Content-Length`, `Connection` or `Transfer-Encoding` |
| Any URL | `http` or `https`, and a host the manifest's `domains` allow, wildcards included |
| An `http.fetch` response body | 10 MB |
| One call to the extension | 30 s (the watchdog, §3.6) |
| Memory for one extension's runtime | 64 MB (§3.6) |
| `storage`, per extension | 1 MB |

The URL rule applies to media and cover URLs as well as to `http.fetch`, so the domains shown on
the permissions screen before install are every domain the source can make the app contact.

## Versioning

`host.apiVersion` is `"1.0"`, and the manifest's `apiVersion` says which version an extension
targets (§3.7). Minor versions only add: new optional methods, new optional fields, new host
functions, new error kinds. An extension checks for a later host feature with `host.has()` rather
than assuming it. A breaking change needs 2.0, with a published deprecation window.

## The Dart mirror

`kikuyomi_source_api` (pure Dart, §2.4) holds:

- `apiVersion`, and the range of versions the app accepts.
- Immutable types matching the ones above: `BookSummary`, `BookDetails`, `ChapterInfo`,
  `ChapterRef`, `ResolveContext`, `MediaResolution`, `MediaSegment`, `HttpRequest`,
  `PageResult<T>`, `SearchQuery`, the sealed `Filter` family and `FilterValues`.
- The sealed `SourceException` family, one class per error kind.
- `abstract interface class ContentSource` with the methods of `Source`, each returning a
  `Future` of those types.
- Decoders from plain data to those types that apply the limits above, shared by the JavaScript
  adapter and the tests so both enforce the same rules.

The JavaScript adapter in `source_runtime` implements `ContentSource` over QuickJS (§3.6).
Built-in sources implement it natively: Local first, replacing the Phase 1 stand-in, then
Audiobookshelf and OPDS. So the rest of the app cannot tell the two apart.

## Changes from the §3.4 sketch

1. `resolveMedia` takes the book's key as well as the chapter's (`ChapterRef`), because a chapter
   key is unique only within its book (§4.4).
2. `ChapterInfo.index` is gone: the array's order is the book's order. `publishedAt` is epoch
   milliseconds rather than a string.
3. Filter values are keyed by each filter's `key` rather than by position.
4. `format` gains `'ogg'`, for Ogg Vorbis. `ResolveContext.network` gains `'unknown'`.
5. `MediaSegment` gains `sizeBytes`.
6. `getHome`, `handleUrl`, `getSettings` and the login flow are left to 1.x (see ADR-0016).
7. Any method may return a value or a Promise, and `getFilters` may be synchronous.
8. Media and cover URLs are held to the manifest's domains, as `http.fetch` already was.
