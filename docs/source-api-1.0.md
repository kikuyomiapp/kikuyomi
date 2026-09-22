# SourceAPI 1.0: the extension contract

**Status: accepted** ([ADR-0016](adr/0016-source-api-1-0.md)). The Dart mirror in
`packages/source_api` implements it; the runtime, the host bridges and the built-in sources do not
yet. The TypeScript SDK that extension authors install lives in a repository of its own; it mirrors
this document and is released under the same API version.

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
| Authors, narrators or genres of one book | 200 each |
| Chapters in one book | 20,000 |
| Segments in one chapter | 2,000 |
| Variants of one segment | 10 |
| Filters, counting those inside groups | 100 |
| Options of one select or sort filter | 1,000 |
| Headers on one request | 50 |
| Header name and value | 256 and 8,192 characters; no `Host`, `Content-Length`, `Connection` or `Transfer-Encoding` |
| A request body | 1 MB of text |
| Any URL | `http` or `https`, and a host the manifest's `domains` allow, wildcards included |
| An `http.fetch` response body | 10 MB |
| One call to the extension | 30 s (the watchdog, §3.6) |
| Memory for one extension's runtime | 64 MB (§3.6) |
| `storage`, per extension | 1 MB |

The URL rule applies to media and cover URLs as well as to `http.fetch`, so the domains shown on
the permissions screen before install are every domain the source can make the app contact.

Every list an extension returns is bounded, and each bound is far above what an honest source
produces. **200 names** is more than the largest collection credits: the widest LibriVox anthologies
run to a few dozen readers. **1,000 options** is longer than any list a person would scroll, and
covers a filter that offers every language or every genre a site knows. **50 headers** is several
times what any site asks for, and a transport would refuse many more. **1 MB of request body** is a
thousand times the largest search form, and a source that needs more is not scraping a page. The
error kinds carry no list at all, and an error's `message` is cut to length rather than refused,
because a kind the app acts on is worth more than the text beside it.

A megabyte here is 2^20 bytes.

## Reading results

Every result is read by the app's decoders, which are the same ones the contract test suite runs
(§3.11), so an extension is held to these rules while it is being written as it is once it is
installed. Below are the rules those decoders apply beyond the Limits table: the cases the types
above leave open. None of them adds anything to the contract.

**Absent.** An optional field may be left out, `undefined` or `null`; all three mean absent, since
`undefined` reaches the app as `null`. A required field that is missing or `null` fails the call.

**Unknown fields are ignored**, so a result written for a later minor version still reads.

**Text.** Lengths count UTF-16 code units, as JavaScript's `length` does, so an author who checks a
limit gets the same answer the app does. Text is trimmed. Short text is one line: tabs and line
breaks fold into single spaces. A description keeps its line breaks, with `\r\n` and `\r` written
as `\n`. Any other control character (U+0000 to U+001F, U+007F) fails the call; characters above
them are kept, including the U+0092 a badly encoded page produces, because that is mojibake rather
than a threat. Optional text that is empty once trimmed is absent, and required text may not be. An
empty entry in `authors`, `narrators` or `genres` is left out rather than failing the call.

**A language** that is not shaped like a BCP 47 tag — a primary subtag of two or three letters, then
any number of subtags — is dropped rather than failing the call: sites write `English` where `en`
belongs, and a label on a book is worth less than the book. What is kept is written the one way
BCP 47 writes it, so that `EN-us` and `en-US` are one language to filter by: the primary subtag in
lower case, a four-letter script subtag in title case, a two-letter region in upper case, the rest
in lower case. This is the only field whose own format is checked; `publishedDate` and `isbn` are
taken as the source gives them, and a `coverUrl` or `webUrl` that breaks the URL rule still fails
the call, because that rule is the promise the permissions screen makes.

**Keys** — a book, chapter or file key, a filter's `key`, an option's `value` — are taken exactly as
written: never trimmed, never folded. They are identities the app matches on (§4.4), and changing
one would break the match. A key holds no control character at all, tabs and line breaks included.

**Numbers.** Every number is whole except `series.index`. It must be finite and within the whole
numbers JavaScript holds exactly (±(2^53 − 1)); a fraction, a `NaN`, an infinity or a larger number
fails the call. Durations, sizes, bitrates and positions are not negative, and a duration, size or
bitrate of `0` is read as "not known", which is what a source with no figure for it usually means.
A time lies within ±8,640,000,000,000,000 ms, the range of a `Date`. `series.index` is finite and
not negative, and need not be whole.

**Enumerations.** An unknown `format` is read as `unknown`, an unknown `status` as `unknown`, and an
unknown `contentRating` as `adult`: the most restrictive value there is, never a laxer one. Every
other unknown value — a filter `kind`, a `method`, a tri-state — fails the call, because there is no
value to fall back to that would not be a guess.

**Duplicates.** Two chapters of one book may not share a key: §4.4 matches chapters by key, and
progress would land on whichever of them was written last. A book key that repeats within one page
keeps its first appearance and the rest are left out, since a site that lists a book twice costs
nothing to drop. Two filters may not share a key, groups included; two options of one filter may not
share a value; two header names may not differ only in case.

**Filters.** The limit of 100 counts headers, separators and groups as well as the filters inside
groups. A group holds no group. A select and a sort each need at least one option, and a `default`,
where there is one, is one of them. Where there is none, the filter starts at `''` for text, `false`
for checkbox, `'ignore'` for tri-state, the first option for select, and nothing chosen for sort,
which leaves the site listing results in its own order.

**Media.** A resolution has at least one segment. A `range.endMs`, where there is one, is after
`range.startMs`. A body belongs only to a POST.

**URLs.** A URL is absolute, `http` or `https`, and carries no user name or password. It holds no
control character, no backslash and no leading or trailing space, and its port, where it has one,
is 1 to 65535. Its host is compared in lower case with a trailing dot ignored. `*.example.org`
matches a subdomain at any depth but not `example.org` itself, so a manifest that needs both lists
both, as §3.3's does. Any port is allowed on an allowed host: a port is not a domain. An IP
address, in any notation, and `localhost` or a subdomain of it are never allowed, in a URL or in
`domains`: an extension names domains, so that the permissions screen can show what it will
contact and so that it cannot reach a device on the listener's own network. An internationalised
name is written in its `xn--` (A-label) form on both sides, since the app has no IDNA
implementation and guessing would be a way past the allowlist. A `domains` entry is a host name of
at least two labels — so `*.com` is refused — with no scheme, port or path, and a `*` only as a
leading `*.`. What the app fetches is the URL as it parsed it, never the extension's text: two
parsers can read one string differently, and handing on the parsed form keeps the host that was
checked the host that is contacted. The rule covers `coverUrl`, `webUrl`, every `request.url`
(segments, variants, `getImageRequest` and `http.fetch`) and `ChallengeRequired`'s `url`.

**Headers.** A name is an HTTP token, 1 to 256 characters. A value is at most 8,192 characters and
holds no control character but a tab. The forbidden names are compared without regard to case.

**Errors.** A thrown error is an object with a `kind` from the Errors table, an optional `message`,
and that kind's own fields. A kind survives a field it does not need: a `RateLimited` whose
`retryAfterMs` is not a number still backs off. A kind whose required field cannot be read does
not, since the app could not act on it: a `ChallengeRequired` without a usable `url` is `Parse`. A
message is never a reason to refuse an error; its control characters are replaced and it is cut to
1,000 characters.

## Versioning

`host.apiVersion` is `"1.0"`, and the manifest's `apiVersion` says which version an extension
targets (§3.7). A version is two whole numbers without leading zeros, `MAJOR.MINOR`, and nothing
else. Minor versions only add: new optional methods, new optional fields, new host functions, new
error kinds. An extension checks for a later host feature with `host.has()` rather than assuming
it. A breaking change needs 2.0, with a published deprecation window.

An app runs an extension that targets a major version it supports at that major's newest minor or
an older one. A newer minor, or a newer major, means the app has to be updated; a major the app no
longer supports means the extension is obsolete.

## The Dart mirror

`kikuyomi_source_api` (pure Dart, §2.4) holds:

- `apiVersion`, `ApiVersion`, and `SupportedApiVersions`, which says whether an extension targeting
  a version is supported, needs a newer app, or is obsolete. It maps each supported major version
  to the newest minor implemented of it rather than holding one range, because during a 2.0
  deprecation window an app supports two majors at once.
- Immutable types with value equality, matching the ones above: `BookSummary`, `BookDetails`,
  `ChapterInfo`, `ChapterRef`, `ResolveContext`, `MediaResolution`, `MediaSegment`, `HttpRequest`,
  `PageResult<T>`, `SearchQuery`, the sealed `Filter` family and `FilterValues`. The names are the
  contract's, with one exception: `format` is a `MediaFormat`, because the app already has an
  `AudioFormat` for what it has found a file to be (§7.3), which is packed differently and is not
  the same claim.
- The sealed `SourceException` family, one class per error kind, and a decoder for a thrown value.
- `abstract interface class ContentSource` with the methods of `Source`, each returning a `Future`
  of those types. Every source has all of them and declares which of the optional three it really
  has in `capabilities`, so that a screen can leave out a Latest tab, or a cover be fetched, without
  calling into the extension at all. Calling an optional method a source does not declare is a
  programming error, not a source failure.
- `SourceLimits`, one constant per row of the Limits table, so that the runtime and the host bridges
  hold to the same figures as the decoders.
- `DomainAllowlist`, built from a manifest's `domains`, which applies the URL rule and hands back
  the parsed URL.
- `PlainDataDecoder`, from plain data to those types, applying the limits and the rules under
  "Reading results". It is shared by the JavaScript adapter and the tests, so both enforce the same
  rules. A refusal names the field: `items[3].title: longer than 1,000 characters`.
- Encoders for what the host passes in — a `SearchQuery` with its `FilterValues`, a `ChapterRef`, a
  `ResolveContext`, a page number — and a reader for a search the app saved, which drops a value
  whose filter the source no longer declares or no longer takes.

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
