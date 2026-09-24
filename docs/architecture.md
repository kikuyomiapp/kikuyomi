# Kikuyomi: Architecture Proposal for a Cross-Platform, Extension-Based Audiobook Player

*Kikuyomi (聞く + 読み, "listen-reading"). Status: v0.3, approved for Phase 0. This revision moves the project from native SwiftUI to Flutter: Android and Windows first, iOS as a planned target. No implementation code is included; interface sketches define contracts, not implementations.*

---

## 0. Executive Summary

The goal is unchanged: a Mihon/Aniyomi-style app for audiobooks, with a native-quality player and library whose content comes from installable, independently versioned source extensions.

What changed is the platform strategy. A native SwiftUI app can only be built with Xcode, which only runs on macOS, and the development machine is a Windows PC. Flutter solves this. Android and Windows can be developed and tested entirely on that PC. iOS stays a build target of the same codebase, compiled in CI today and developed properly once a Mac is available. macOS and Linux come almost for free later. Mangayomi proves that this exact category of app, extension-based media with repositories and sideloaded iOS builds, works in Flutter across all five platforms.

The core decisions are these.

**Flutter (Dart) for the entire app.** One UI with adaptive layouts: phone, tablet, and desktop windows. Anything that differs by operating system (audio backends, media controls, background work, file access) sits behind interfaces with per-platform implementations, so features never contain platform checks.

**Extensions remain signed JavaScript bundles, authored in TypeScript, executed in an embedded QuickJS engine.** Android could load native APK extensions the way Mihon does, but those would never run on Windows or iOS. JavaScript is the only extension format that runs everywhere, so every extension written for the Android release will work unchanged on iOS later. QuickJS also supports interrupt handlers and memory limits, which fixes the watchdog weakness that JavaScriptCore had in v0.2.

**Built-in native sources** (Local files, Audiobookshelf, OPDS) implement the same contract as extensions, so the app is a complete audiobook player with no extensions installed.

**The audiobook data model is unchanged from v0.2.** Logical chapters are separated from physical audio files, a computed Timeline maps between them, and progress is stored chapter-relative.

**Drift (SQLite) for persistence, Riverpod for state and dependency injection, go_router for navigation**, with the core logic in pure-Dart packages that can be tested on any machine in seconds.

**Playback uses `just_audio`, `audio_service`, and `audio_session`** behind a `PlaybackEngine` interface. That means ExoPlayer on Android, AVPlayer on iOS, and an mpv-based backend on Windows.

**Downloads use a database-backed queue with `background_downloader` as the transport**, and URLs are resolved just in time because many sources hand out expiring links.

**Distribution is sideload-first on every platform.** APKs and Windows builds ship through GitHub Releases with in-app update checks; iOS later ships through AltStore/SideStore. Google's Android developer verification program changes Android sideloading from late 2026 onward, so the plan includes registering as a verified developer.

Section 9 lists the decisions that need approval. Appendix A preserves the iOS-specific findings from v0.2 for when the iOS target is built.

---

## 1. Analysis of Mihon, Aniyomi, and Mangayomi

### 1.1 How Mihon is built

Mihon is the maintained successor to Tachiyomi, which was discontinued in January 2024 after legal pressure from a rights holder. It is a Kotlin/Android app split into Gradle modules along clean-architecture lines: `domain` (entities and interactors, i.e. use cases), `data` (SQLDelight-backed repositories), `source-api` (the extension contract), `source-local` (the local-files source), `core`, `presentation-core`, and `i18n`, with `app` as the composition root and UI layer.

**Extensions** are separate APKs. Each declares a feature flag and the class name of its source in its Android manifest. The host discovers installed extension packages through the PackageManager, loads the named class through a ClassLoader, and instantiates either a `Source` or a `SourceFactory` (one extension producing many sources, typically one per language). Extensions compile against a stub library; the host supplies the real implementations of networking (OkHttp), HTML parsing (Jsoup), and helper base classes at runtime. This "compile against stubs, host provides the implementation" pattern is what keeps extensions tiny and the API stable.

**The source hierarchy** is layered by capability. `Source` provides details, chapter list, and page list. `CatalogueSource` adds language, popular/latest/search, and filters. `HttpSource` adds a base URL, an HTTP client, and paired `xxxRequest()`/`xxxParse()` methods for each operation. `ParsedHttpSource` reduces common sites to CSS selectors. Marker interfaces such as `ConfigurableSource` add optional capabilities like per-source settings.

**Identity** is handled carefully. A source's ID is a 64-bit value derived from a hash of its lowercase name, language, and a `versionId` integer, so the ID survives package renames and domain changes. Manga and chapters are stored by *relative* URL, so a site moving domains doesn't orphan the library. Extension-facing DTOs (`SManga`, `SChapter`) are kept separate from domain entities and mapped at the boundary. When an extension is uninstalled, library entries keep pointing to a placeholder "stub" source instead of being deleted.

**Repositories** are static JSON indexes (an extension list plus a `repo.json` carrying the signing key fingerprint) hosted anywhere, typically GitHub. Mihon ships with no default repositories; users add them by URL. Extensions signed with an unknown key must be explicitly trusted.

**Supporting subsystems** include a library with categories that carry their own sort/filter/display settings, a background library-update job that checks for new chapters and feeds an Updates tab, reading history, a downloader with a queue and per-source concurrency limits, gzipped protobuf backups designed for forward compatibility, external trackers (AniList, MyAnimeList, and others), migration of an entry from one source to another while preserving progress, and a WebView-based interceptor for Cloudflare challenges.

### 1.2 What Aniyomi adds

Aniyomi is a Tachiyomi fork that bolts anime onto the manga app. It introduces a parallel hierarchy (`AnimeSource`, `AnimeHttpSource`, `SAnime`, `SEpisode`) and, critically, a `Video` type resolved *at play time* through a `getVideoList(episode)` call. A video carries a URL, a quality label, required HTTP headers, and subtitle/audio tracks. Playback is handled by an embedded mpv player.

Two lessons come from Aniyomi. The first is that media resolution must be lazy: stream URLs are ephemeral, header-dependent, and often come in quality variants, so they are fetched immediately before use rather than stored. Audiobooks have exactly this problem shape, which makes Aniyomi the closer model for the content pipeline. The second lesson is a warning: adding a second media type by duplicating tables, repositories, and screens produced a large parallel codebase. We are building for one media type, so we should design the audiobook model properly from the start instead of forcing it into a manga-shaped mold.

### 1.3 What Mangayomi shows

Mangayomi is the closest existing precedent for this project's new direction. It is an open-source (Apache-2.0) Flutter app, with a Rust component connected through `flutter_rust_bridge`, that reads manga and novels and plays anime on Android, iOS, macOS, Linux, and Windows from one codebase. Its sources are distributed through JSON-indexed repositories that users add, like Mihon's, and extensions can be written in either Dart or JavaScript. Its iOS builds are distributed through AltStore and SideStore sources.

Three lessons come from it. First, it proves that Flutter can carry an extension-based media app, including background media playback, across all five platforms, and that the sideload channel for iOS is workable. Second, supporting two extension languages means two runtimes, two SDKs, two sets of documentation, and two testing stories; this project picks one. Third, a generic media model spanning manga, anime, and novels buys breadth at the cost of depth in each; this project stays audiobook-specific.

Mangayomi is also the codebase to read when a Flutter platform problem gets stuck, because it has already solved many of the same ones.

### 1.4 Adopt, adapt, or reject

| Concept (Mihon/Aniyomi) | Decision | Notes for Kikuyomi |
|---|---|---|
| Source as the unit of content; one extension may provide many sources | **Adopt** | Extension manifest lists its sources. |
| Stub library + host-provided implementations | **Adapt** | TypeScript typings + host "bridges" (HTTP, HTML, crypto) implemented by the app. |
| APK packages loaded via ClassLoader | **Reject** | Possible on Android, impossible on iOS, and meaningless on desktop. Signed JS bundles run everywhere. |
| User-added JSON repositories with signing fingerprints | **Adopt** | Ed25519 signatures, trust-on-first-use pinning. |
| Stable hashed source IDs, `versionId` bump for breaking changes | **Adopt** | Hash includes extension ID to avoid cross-repo name collisions. |
| Relative URLs as persistent identifiers | **Adopt** | Generalized to an opaque `key` string chosen by the extension. |
| DTO ↔ domain entity separation | **Adopt** | Strict decoding and validation at the boundary. |
| Filter model (Text, Select, Sort, CheckBox, TriState, Group) | **Adopt** | Same kinds; familiar to extension authors. |
| `request()`/`parse()` split in the contract | **Adapt** | Contract is plain async methods; the split lives in an optional SDK base class. |
| Lazy media resolution (Aniyomi `getVideoList`) | **Adopt** | `resolveMedia()` with expiry and quality variants. |
| Loading every extension at app start | **Reject** | Manifest-first registry; runtimes created lazily and pooled. |
| Background library-update job | **Adapt** | Less central for finished books, still useful for serialized productions. WorkManager on Android, on launch and while running on desktop, best-effort on iOS. |
| Categories with per-category settings | **Adopt** | Plus smart collections and series grouping. |
| Source migration | **Adopt, with care** | Different sources may carry different editions or narrators; compare durations. |
| Trackers | **Adapt, later** | Audiobookshelf progress sync, Hardcover; Goodreads has no open API. |
| Protobuf backups | **Adopt** | Field-number discipline for forward/backward compatibility. |
| Local source | **Adopt, promoted** | A first-class feature; the app is useful with no extensions installed. |
| Stub source for uninstalled extensions | **Adopt** | Library survives uninstalls. |
| WebView challenge solving | **Adopt** | Interactive only; user-visible. |
| Parallel media hierarchies (Aniyomi) | **Reject** | One well-designed audiobook model. |

### 1.5 Where audiobooks genuinely differ

Consumption is continuous time, not discrete pages. Progress is a timestamp, users expect resume accuracy within seconds, and "continue listening" is the most important screen in the app, not a secondary history list.

Physical files do not map to logical chapters. The four real-world layouts are: one file per chapter; one large file (usually M4B) with embedded chapter markers; one chapter split across several files; and many files with no relationship to chapter boundaries. The model must represent all four without special-casing screens.

Files are large (hundreds of megabytes to over a gigabyte), durations are often unknown until a file is probed, and variable-bitrate MP3s seek imprecisely, which causes resume positions to drift.

Most audiobooks are finished works. "New chapters available" matters far less than in manga, though serialized audio dramas and similar content still need it.

Playback carries system-integration obligations that reading never had: lock screen, interruptions from calls and navigation prompts, headphone disconnects, Bluetooth and car integration, media keys on desktop, and correct behavior while a phone is locked.

Commercial audiobooks are a concentrated market with active enforcement, which raises the stakes of the legal questions discussed in Section 7.

---

## 2. Overall Architecture

### 2.1 Principles

The dependency rule is strict: presentation depends on domain, infrastructure implements domain interfaces, and only the app package knows concrete types. The domain layer is pure Dart with no Flutter or platform dependencies. Everything the user owns (library, progress, downloads, bookmarks) lives locally and works offline; the network is used for browsing, searching, refreshing, and streaming only. Every external boundary (extensions, network, filesystem, audio engine, clock) sits behind an interface so the logic around it can be tested with fakes. Platform differences live in adapters, never as scattered platform checks inside features. Extension code is treated as untrusted input: its outputs are validated, its capabilities are minimal, and its failures are contained.

### 2.2 Platform strategy

| Platform | Status | How it's developed and tested | Notes |
|---|---|---|---|
| Android | Primary | Emulator on the Windows PC; a cheap used Android phone later, because real devices kill background work in ways emulators don't | Minimum Android 8.0 (API 26) proposed |
| Windows | Primary | Natively on the PC | Windows 10 and later |
| iOS | Planned | CI builds an unsigned IPA on a macOS runner; you install it on your iPhone from Windows with Sideloadly or AltServer and test with logs only. Full development once a Mac is available | See Appendix A |
| macOS, Linux | Later | CI builds only | Low cost with Flutter |

Every dependency must support Android, Windows, and iOS, or sit behind an adapter that has a known alternative on the missing platform. The iOS CI build runs from Phase 0 onward as a canary, so iOS never silently stops compiling.

### 2.3 Layer diagram

```
┌──────────────────────────── app (Flutter composition root) ──────────────────────────┐
│ Features: Library · Home · Browse · Search · BookDetail · Player · Downloads ·       │
│           Extensions · Settings · Backup        (widgets + Riverpod notifiers)       │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ domain (pure Dart): entities · use cases · repository & service interfaces · Timeline│
├──────────────┬────────────────┬───────────────┬────────────────┬─────────────────────┤
│ data (Drift) │ source_runtime │ downloads     │ playback       │ backup · sync       │
│ repositories │ QuickJS host + │ queue, state  │ coordinator,   │ protobuf, folder,   │
│ migrations   │ native sources │ machine       │ sleep timer    │ WebDAV              │
├──────────────┴────────────────┴───────────────┴────────────────┴─────────────────────┤
│ platform_adapters: audio backend · media session · download transport · storage ·    │
│ folder access · secure storage · WebView challenge · power policy     (per OS)      │
└──────────────────────────────────────────────────────────────────────────────────────┘
        ▲
  source_api (stable, versioned contract) ◄── Extension SDK (TypeScript, npm) ◄── authors
```

### 2.4 Package map

The repository is a Dart pub workspace (with Melos for scripts). Core logic lives in **pure-Dart packages** with no Flutter dependency: they test in seconds with `dart test` on any machine and can be reused by command-line tools. Flutter-dependent code is limited to the app package, the design system, and the platform adapters. UI features live as feature folders inside the app package; splitting every screen into its own package adds overhead without real benefit for a solo developer. Folder names stay short, but each package under `packages/` carries a `kikuyomi_` prefix in its `pubspec` name (for example `kikuyomi_domain`) so it can never collide with a published package of the same name. The prefix applies only to those packages: the app package keeps the bare name `kikuyomi`, because its package name feeds the application ID and Android namespace fixed in decision 15.

| Package | Kind | Responsibility | Depends on |
|---|---|---|---|
| `app` | Flutter app | Composition root, routing, theming, adaptive shell, platform bootstrap, feature folders (views + notifiers) | Everything |
| `source_api` | Pure Dart | Dart mirror of the extension contract: DTOs, `ContentSource` interface, filters, settings, capabilities, API version | None |
| `domain` | Pure Dart | Entities, use cases, repository/service interfaces, Timeline computation | `source_api` |
| `data` | Dart + Drift | Drift schema, migrations, repository implementations, mappers, merge rules | `domain`, Drift |
| `networking` | Pure Dart | HTTP client abstraction, per-extension cookie jars, rate limiter, caching | None (platform HTTP clients injected) |
| `source_runtime` | Dart + FFI | QuickJS host, bridges, worker-isolate pool, watchdog, output validation | `source_api`, `networking` |
| `sources_builtin` | Pure Dart | Local, Audiobookshelf, OPDS | `source_api`, `networking` |
| `extension_manager` | Pure Dart | Repositories, index fetching, install/update/uninstall, signatures, trust store, `SourceRegistry` | `source_api`, `source_runtime`, `sources_builtin`, `domain` |
| `downloads` | Pure Dart | Queue, scheduler, state machine, post-processing, storage accounting (transport behind an interface) | `domain`, `networking` |
| `playback` | Pure Dart | `PlaybackCoordinator`, progress store, sleep timer, resume rules (engine behind an interface) | `domain` |
| `backup` | Pure Dart | Protobuf schema, export/import, restore planner | `domain` |
| `sync` (later) | Pure Dart | `SyncBackend` implementations: user-chosen folder, WebDAV, Audiobookshelf | `domain`, `backup` |
| `platform_adapters` | Flutter | Audio backend, media session, download transport, storage locations, folder access, secure storage, WebView challenge, power policy, diagnostics | The interfaces above |
| `design_system` | Flutter | Theme, typography, components (cover, progress ring, chapter row), adaptive scaffolds, image loading | None |
| `test_support` | Pure Dart | Fakes, fixtures, in-memory Drift database, fake clock | `domain` |

The main third-party dependencies are Drift with bundled SQLite (`sqlite3_flutter_libs`), Riverpod, go_router, protobuf, `just_audio` (plus `just_audio_media_kit` for Windows), `audio_service`, `audio_session`, `background_downloader`, `flutter_inappwebview`, `flutter_secure_storage`, `path_provider`, the Dart `html` parser, the Dart `crypto` package plus an AES implementation, and a QuickJS binding chosen in Phase 0.

### 2.5 Why these technology choices

**Flutter over Kotlin Multiplatform.** Kotlin Multiplatform with Compose Multiplatform was the strong alternative: Kotlin is close to Java and Mihon's code is Kotlin. But this is an audio app, and in Kotlin Multiplatform the player, background playback, media controls, and download transport would each be written separately per platform, with weak audio options on the JVM desktop. Flutter has mature packages for all of those across Android, iOS, and desktop, first-class Windows support, hot reload, and a working precedent in Mangayomi. The trade-off is that Flutter draws its own widgets, so "modern native design" means Material 3 done well with platform-appropriate adaptations rather than literal native controls.

**Dart** will feel familiar from Java: classes, interfaces, static types, generics, and async/await, plus sound null safety, sealed classes, and pattern matching, which suit UI state modeling well.

**Drift over Isar, Hive, or sqflite.** The library is a relational problem (filters, sorts, category joins, full-text search). Drift provides typed SQL, versioned migrations with generated schema snapshots for migration tests, reactive `watch()` queries, FTS5, execution in a background isolate, and support for every target platform. Isar, which Mangayomi uses, has had maintenance gaps; plain sqflite lacks Windows support without extra work and has no reactive layer.

**Riverpod** handles both state management and dependency injection, works outside the widget tree (important for the playback coordinator and services), and makes tests easy through provider overrides. Bloc is the main alternative.

**go_router** gives declarative routing, deep links, and typed routes.

### 2.6 Presentation and navigation

The shell is adaptive. Phones get a bottom navigation bar; wide windows (Windows desktop, tablets) get a navigation rail or side panel. The four tabs stay the same as in v0.2: **Library**, **Home** (Continue Listening, recently played, updates), **Browse** (Sources, Extensions, global search, migration), and **More** (Downloads, History and Stats, Settings, Backup). On phones a mini-player sits above the navigation bar and opens a full-screen player; on desktop a persistent player bar runs along the bottom of the window, in the style of desktop music apps.

Desktop gets the details desktop users expect: keyboard shortcuts (space to play or pause, arrow keys to seek, brackets for speed), hardware media keys, drag-and-drop import of folders, remembered window size and position, and optional minimize-to-tray so playback and downloads continue with the window closed.

Deep links (`kikuyomi://add-repo?url=…`, `kikuyomi://book/…`) use an intent filter on Android and a protocol handler registered by the Windows installer. Android 12+ gets Material dynamic color. Localization uses Flutter's ARB-based `gen-l10n`, and right-to-left layouts come from Flutter's built-in directionality support.

Screens use Riverpod notifiers that call use cases and expose immutable state. The database is the single source of truth: notifiers observe Drift `watch()` streams, so a finished download, a completed refresh, or a progress save updates every screen that shows it.

### 2.7 Concurrency model

Dart runs code in isolates, which share no memory and communicate by messages.

The **main isolate** runs the UI, Riverpod, the playback coordinator, and the `audio_service` handler.

The **database** runs in a background isolate through Drift, so queries never block frames.

**Extension execution** runs in a small pool of worker isolates (for example two on phones and four on desktop). Each worker hosts several QuickJS runtimes, one per extension, and HTML parsing happens in the same worker, so CPU-heavy parsing never touches the UI thread.

**Network requests** made by extensions go through a single `NetworkService` that owns the cookie jars and rate limiters, with response bodies sent back to the worker as transferable byte buffers. If profiling shows contention, the service can move to its own isolate without changing its interface.

### 2.8 Dependency injection

Riverpod providers form the dependency graph. At startup the app selects the platform adapter implementations for the current OS and exposes everything through providers. The pure-Dart packages never import Riverpod; they receive dependencies through constructors, and the providers that construct them live in the app package. Tests override providers with fakes.

### 2.9 A representative flow: browse, open, play

When a user opens a source, the Browse notifier calls the `GetPopularBooks` use case, which asks the `SourceRegistry` for the source by ID. If it's a JavaScript extension whose runtime isn't warm, the registry starts one in a worker isolate. The extension's DTOs are validated and mapped to lightweight `BookSummary` values held in memory; nothing is written to the database for books the user merely scrolls past.

Opening a book runs `RefreshBookDetails`, which upserts the book and synchronizes its chapter list using the merge rules in Section 4.4. The detail screen watches the database, so it renders cached data instantly and updates when the refresh completes.

Pressing play calls `StartPlayback`. The coordinator builds the book's Timeline and resolves media for the target chapter: a downloaded file if one exists, otherwise a cached resolution that hasn't expired, otherwise a fresh `resolveMedia` call to the extension. The audio engine is then loaded with the resulting items.

### 2.10 Quality strategy

Pure-Dart packages are unit-tested with `dart test`, which is fast enough to run on every save. Drift migrations are tested against generated schema snapshots for every schema version. The playback coordinator is tested against a fake engine and a controllable clock, which makes timeline math, progress saving, sleep timers, and resume rules deterministic. The extension runtime has contract tests that load real sample extensions into QuickJS on every CI platform. The design system gets widget and golden tests. A small set of integration tests covers the critical path (import a book, play, background, resume) on an Android emulator in CI, and manual device scripts cover background behavior that emulators can't reproduce.

CI runs on GitHub Actions, which is free for public repositories: Linux for tests and Android builds, Windows for the Windows build, and macOS for the iOS canary.

### 2.11 Development environment on Windows

The setup consists of the Flutter SDK (stable channel); VS Code with the Dart and Flutter extensions and Claude Code; Android Studio for the Android SDK, the emulator, and Android-side debugging (with hardware virtualization enabled in the BIOS so the emulator is fast); the full Visual Studio IDE with the "Desktop development with C++" workload, which Flutter requires for Windows builds even if you write code in VS Code; Git; and Node.js LTS for the extension SDK. A Rust toolchain is needed only if Phase 0 selects the Rust-based QuickJS binding. `flutter doctor` should report Android and Windows as ready before Phase 0 starts.

---

## 3. Extension System

### 3.1 Choosing the extension format and engine

| Option | Runs on | Author experience | Power | Verdict |
|---|---|---|---|---|
| Native APK extensions (Mihon model) | Android only | Good (Kotlin) | Full | Rejected: would strand the Windows and iOS versions and split the ecosystem |
| Dart source run by an interpreter | All platforms | Dart only; interpreters are slower and less mature; small author pool | Medium | Rejected for v1 (Mangayomi supports it alongside JS) |
| **JavaScript in an embedded engine** | All platforms | Excellent: TypeScript, npm tooling, the largest pool of people who already write scrapers | High | **Chosen** |
| WebAssembly in an interpreter | All platforms | Rust or similar; heavier toolchain; smaller author pool | High | Viable; rejected for v1 on ecosystem grounds |
| Declarative rule files (JSON with CSS selectors) | All platforms | Easy for simple sites | Low | Later, implemented as a generic "template" extension |

**The engine is QuickJS.** It is a small, embeddable JavaScript engine written in C that supports modern JavaScript and builds for Android, Windows, iOS, macOS, and Linux. Unlike V8 it needs no JIT (which iOS forbids to third-party apps anyway), and unlike JavaScriptCore it runs identically everywhere. Two QuickJS features matter a great deal: an **interrupt handler** that lets the host stop a runaway script, and a **per-runtime memory limit**. Both were missing from JavaScriptCore's public API in the v0.2 design.

**The Dart binding is chosen in Phase 0**, because the maturity of QuickJS bindings in the Flutter ecosystem varies and this is the most important dependency in the project. Candidates are evaluated against explicit criteria: Promise/async support with a host-driven job loop, access to the interrupt handler and memory limit, builds for Android, Windows, and iOS, safe use inside a Dart isolate, and recent maintenance activity. The candidates are an existing Dart QuickJS FFI package, or a thin Rust layer using the `rquickjs` crate through `flutter_rust_bridge` (the toolchain Mangayomi already uses). The preference is whichever meets every criterion with the least toolchain; the Rust route is the fallback that guarantees full control. Either way the engine sits behind a `ScriptEngine` interface, so it can be replaced later, for example by JavaScriptCore on Apple platforms if that ever becomes necessary.

### 3.2 Concepts

A **Repository** is an HTTPS location serving a `repo.json` (name, website, public signing key), an `index.json` (the list of available extensions), the packages themselves, and icons. Users add repositories by URL or deep link.

An **Extension** is one signed package containing a manifest, a single bundled JavaScript file, and an icon. It can expose one or many sources (for example, one per language or mirror), the equivalent of Mihon's `SourceFactory`.

A **Source** is the runtime unit the app talks to, identified by a stable 64-bit ID. Built-in native sources are also Sources and are indistinguishable to the rest of the app.

### 3.3 Package format

```
org.example.librivox-14.kyx            (a zip archive)
├── manifest.json
├── main.js        single bundled ES2020 file, no imports, produced by the SDK CLI
├── icon.png
└── SIGNATURE      Ed25519 signature over the exact bytes of manifest.json
```

The manifest contains the SHA-256 of every other file, and the signature covers the manifest, so verifying the signature transitively verifies the whole package.

```json
{
  "id": "org.example.librivox",
  "name": "LibriVox",
  "version": "1.4.0",
  "versionCode": 14,
  "apiVersion": "1.2",
  "minAppVersion": "1.0.0",
  "author": "Example Maintainers",
  "contentRating": "everyone",
  "domains": ["librivox.org", "archive.org", "*.us.archive.org"],
  "capabilities": ["latest", "filters", "settings"],
  "sources": [
    { "key": "librivox", "name": "LibriVox", "lang": "en", "versionId": 1 }
  ],
  "files": { "main.js": "sha256-…", "icon.png": "sha256-…" }
}
```

`contentRating` is one of `everyone`, `mature`, or `adult`. `domains` is an enforced allowlist for the HTTP bridge, which doubles as a privacy guarantee and a line item on the permissions screen. The repository `index.json` repeats the essential metadata (ID, version, API version, languages, sources, content rating, package URL, package hash, icon URL) so that the app can present and filter available extensions without downloading any code.

### 3.4 The source contract (SourceAPI v1)

This is the stable API between the app and extensions. It is shown in TypeScript because that is what authors will write against; the Dart `source_api` package mirrors it one-to-one.

```ts
// Contract sketch: shape only, not implementation.

interface Source {
  // Discovery
  getHome?(): Promise<HomeSection[]>                        // optional rich landing page
  getPopular(page: number): Promise<PageResult<BookSummary>>
  getLatest?(page: number): Promise<PageResult<BookSummary>>
  search(query: SearchQuery, page: number): Promise<PageResult<BookSummary>>
  getFilters?(): Filter[]

  // Content
  getBookDetails(bookKey: string): Promise<BookDetails>
  getChapters(bookKey: string): Promise<ChapterInfo[]>
  resolveMedia(chapterKey: string, ctx: ResolveContext): Promise<MediaResolution>

  // Optional capabilities
  getSettings?(): SettingDefinition[]
  handleUrl?(url: string): Promise<UrlMatch | null>          // "open this link in Kikuyomi"
  getImageRequest?(url: string): Promise<HttpRequest>       // headers needed for covers
}

interface BookSummary { key: string; title: string; coverUrl?: string;
                        authors?: string[]; narrators?: string[]; durationMs?: number }

interface BookDetails {
  key: string; title: string; subtitle?: string
  authors: string[]; narrators: string[]
  series?: { name: string; index?: number }
  description?: string; coverUrl?: string; genres: string[]
  language?: string; publisher?: string; publishedDate?: string; isbn?: string
  abridged?: boolean; totalDurationMs?: number
  status: 'complete' | 'ongoing' | 'unknown'
  contentRating?: 'everyone' | 'mature' | 'adult'
  webUrl?: string
}

interface ChapterInfo { key: string; title: string; index: number
                        durationMs?: number; publishedAt?: string; group?: string }

interface ResolveContext { purpose: 'stream' | 'download'; network: 'wifi' | 'cellular' }

interface MediaResolution {
  segments: MediaSegment[]          // played in order, they form this chapter
  expiresAt?: number                // epoch ms; the host re-resolves after this
}

interface MediaSegment {
  fileKey: string                   // stable ID of the physical file; dedupes shared files
  request: HttpRequest              // url, headers, optional method/body
  format?: 'mp3' | 'm4a' | 'm4b' | 'aac' | 'flac' | 'opus' | 'hls' | 'unknown'
  range?: { startMs: number; endMs?: number }   // sub-range of the file
  durationMs?: number
  variants?: { label: string; bitrateKbps?: number; request: HttpRequest }[]
}
```

The `fileKey` and `range` fields are what let one contract describe all four audiobook layouts. A single M4B with thirty chapters is thirty chapters that each resolve to the same `fileKey` with different ranges; the download engine sees one file and downloads it once. A chapter split into three files resolves to three segments. A source that only knows "here is the book file" returns one chapter, and the app derives display chapters from the file's embedded markers after probing it.

`ResolveContext` lets a source choose quality: a smaller variant when streaming on cellular, the best one for downloads.

**Filters** use the same kinds Mihon authors know: Header, Separator, Text, CheckBox, TriState, Select, Sort, and Group.

**Settings** are declared, not rendered, by the extension: toggle, text, select, multi-select, secret (stored in platform secure storage), and a login action that asks the host to open an interactive web login.

**Errors** are typed so the host can react intelligently rather than just displaying a message:

| Error | Host reaction |
|---|---|
| `ChallengeRequired(url)` | Present a WebView to the user, sync resulting cookies, retry once |
| `LoginRequired` | Offer the source's login flow |
| `RateLimited(retryAfter)` | Back off; pause that source's download queue |
| `NotFound` | Mark book or chapter as unavailable at source |
| `SourceOutdated` | Suggest an extension update |
| `Network`, `Parse` | Retry with backoff; count toward extension health |

### 3.5 The host API (what extensions can do)

The host API is intentionally small. Everything not listed is impossible.

| Module | Capability | Constraints |
|---|---|---|
| `http` | `fetch(request)` returning status, headers, and body as text, bytes, or JSON | Only manifest-declared domains; per-source rate limit; per-extension cookie jar; host-controlled User-Agent; body size cap; timeout |
| `html` | `parse(text)` returning a document with CSS `select`, `text`, `attr`, `html` | Implemented by the host with a Dart HTML parser (selector coverage checked in Phase 0); read-only; page scripts never execute |
| `crypto` | MD5/SHA hashes, HMAC, Base64, AES decrypt | Implemented by the host; policy forbids DRM-related use |
| `storage` | Namespaced key-value store for preferences and small caches | Per-extension, size-capped; secrets go to platform secure storage (Android Keystore, Windows Credential Manager, iOS Keychain) |
| `ui` | `requestInteractive(url)` asking the user to complete a challenge or login in a WebView | Always visible to the user in v1. A permission-gated headless `webview.render(url)` for JavaScript-rendered sites is planned for API 1.x on platforms that support headless WebViews; its costs are memory and that it only runs while the app is active |
| `log` | Leveled logging into an in-app extension console | Rate-limited |
| `host` | `apiVersion`, `has(feature)` for capability detection | Read-only |

Extensions cannot touch the filesystem, the library database, other extensions' data, or any device API. The app never passes library contents to an extension. This narrowness is a security decision: extension code comes from third parties the user may barely know, so the smaller the surface, the less a malicious or careless extension can do.

A small JavaScript prelude (polyfills such as `setTimeout`, `TextDecoder`, and `URL`, plus the bridge shims) ships *inside the app*, so no part of the runtime environment itself is downloaded.

### 3.6 Runtime design

The **`SourceRegistry`** knows every installed source from manifests alone. App launch never executes extension code, which is what keeps hundreds of installed sources cheap.

A **`JsSourceAdapter`** implements the Dart `ContentSource` interface by forwarding calls to an **`ExtensionRuntime`**: one QuickJS runtime and context per extension (not per source), created on first use inside one of the worker isolates and confined to it.

Runtimes are **pooled** with least-recently-used eviction (for example twelve warm runtimes across the pool, evicted after five idle minutes or when the OS signals memory pressure). The exact numbers come out of Phase 0 measurements of per-runtime memory and cold-start time.

Calls are asynchronous in both directions. The main isolate sends a request to the worker; the worker invokes the extension method, which returns a Promise; the worker pumps QuickJS's job queue until the Promise settles. When JavaScript calls a bridge such as `http.fetch`, the worker forwards the request to the `NetworkService`, receives the response bytes, and resolves the Promise inside the runtime.

Every value returned by an extension is decoded into strict Dart types with size limits. Malformed output becomes a typed error, never a crash and never a partially written database row.

The **watchdog** enforces a per-call deadline (30 seconds by default) through QuickJS's interrupt handler: the engine checks the handler periodically while running JavaScript, and once the deadline passes the script is aborted with an exception. A per-runtime memory limit (for example 64 MB) turns runaway allocation into an error instead of an out-of-memory crash. An extension that repeatedly trips either limit is marked unhealthy and disabled with a notice.

One honest limitation remains. Isolates protect the UI from slow code, but not from native crashes: a bug inside the QuickJS C code itself would take down the whole app process. The mitigations are choosing a mature binding, running the contract test suite against every release, and keeping the host API surface small.

### 3.7 Versioning and compatibility

`apiVersion` is `MAJOR.MINOR`. Minor versions are strictly additive: new optional methods, new optional fields, new host functions. Major versions may break. The app declares the range it supports. An extension targeting a newer minor than the app supports shows "update the app"; one targeting an unsupported older major is marked obsolete. Extensions detect optional host features at runtime with `host.has(...)` rather than assuming them.

A source's ID is the first 8 bytes of SHA-256 over `"{extensionId}/{sourceKey}/{lang}/{versionId}"`. Unlike Mihon, the extension ID is included so that two repositories can never collide by choosing the same display name. Display names and domains can change freely. Authors bump `versionId` only when their book/chapter keys become incompatible, which triggers a migration prompt for affected library entries.

### 3.8 Trust and security

Each repository has an Ed25519 signing key published in `repo.json`. On first add, the app shows the key fingerprint and pins it (trust on first use). Every package's manifest signature and file hashes are verified at install and re-checked cheaply at load. Updates must be signed by the pinned key; a key rotation must be signed by the old key, or the user must explicitly re-trust the repository.

Before install, users see a permissions summary: the domains the extension will contact, its content rating, and whether it has settings or a login flow. Repository indexes can mark specific versions as revoked, which disables them on next index refresh. Adult-rated extensions are hidden unless the user opts in.

### 3.9 Lifecycle

Adding a repository fetches its index (cached with ETags). Installing downloads the package, verifies it, unpacks it into a versioned directory, and registers its sources. On Android this is a clear improvement over Mihon: installing an extension is a file download, not an APK install, so there are no system install prompts and no "install unknown apps" permission per extension. Update checks run on launch (at most daily) and on demand. Updates install side by side and switch atomically, keeping the previous version for rollback. Uninstalling removes the code but not the user's data: library books from that source keep their metadata, progress, and downloads, and point to a stub source until the extension returns or the books are migrated.

### 3.10 Built-in sources and the official repository

Three sources are compiled into the app.

**Local** covers folders the user chooses. On Android these are picked through the Storage Access Framework and the permission is persisted; on Windows any folder path works, including drag-and-drop; on iOS (later) they are held through security-scoped bookmarks. A folder is a book and its files are tracks. Metadata comes from ID3 and MP4 tags. M4B chapter markers need a small MP4 chapter parser, because the audio plugins don't expose embedded chapters; Phase 0 confirms the approach (a compact Dart parser, or a Rust crate if the Rust bridge is adopted anyway).

**Audiobookshelf** connects to a user's self-hosted server, with native progress sync.

**OPDS** reads OPDS 2 catalogs, including Readium audiobook manifests.

Separately, an **official repository** hosts JavaScript extensions. It proves the whole extension pipeline end to end, serves as the reference implementation extension authors copy from, and gives new users something to listen to on first launch. Third-party repositories are user-added only; the app never recommends or lists them, for the legal reasons in Section 7.1.

### 3.11 Extension developer experience

A healthy ecosystem depends on making extensions easy to write and hard to get wrong.

The SDK is an npm package providing TypeScript typings for the contract and host API, an optional `HttpSourceBase` class with Mihon-style `request`/`parse` pairs, and helpers for common patterns. Its CLI provides `init` (scaffold from a template), `build` (bundle to one ES2020 file with esbuild), `test` (run the extension against live sites or recorded fixtures), `sign`, `index` (generate `index.json`), and `serve` (host a repository on the local network for on-device testing).

Every extension must pass a **contract test suite**: popular returns results, details load for the first result, chapters are non-empty, and `resolveMedia` yields a URL whose HEAD request returns audio. Because Node runs V8 and the app runs QuickJS, the test runner executes extensions inside QuickJS compiled to WebAssembly, so tests run on the same engine as the app and engine differences surface before release.

In the app, a developer mode adds a local-network repository, live reload on rebuild, and an extension log console.

---

## 4. Data Models

### 4.1 Three model layers

**SourceAPI DTOs** are what extensions produce. **Domain entities** are immutable value types the app reasons about. **Database records** are Drift rows. Mappers in the `Data` module convert between them, and no DTO or record type ever reaches a view. This is the same discipline Mihon uses with `SManga` versus `Manga`, and it is what allows the extension contract and the database schema to evolve independently.

### 4.2 Entity relationships

```
repository 1─* extension 1─* source 1─* book 1─* chapter 1─* chapter_segment *─1 media_file
                                         │                                             │
                                         ├─*─* category (via book_category)            1
                                         ├─*─* person   (via book_person, role)        │
                                         ├─1   playback_state                          *
                                         ├─*   listening_session                  download_task
                                         ├─*   bookmark
                                         └─*   tracker_link (later)
```

### 4.3 Tables

**`book`**: `id` (surrogate integer key), `source_id`, `key` (unique together with `source_id`), `title`, `subtitle`, `description`, `cover_url`, `cover_local_path`, `cover_updated_at`, `series_name`, `series_index`, `genres` (JSON), `language`, `publisher`, `published_date`, `isbn`, `abridged`, `status`, `content_rating`, `total_duration_ms`, `web_url`, `in_library`, `date_added`, `last_refreshed_at`, `details_fetched`, `user_overrides` (JSON map of fields the user edited), `playback_speed` (per-book speed memory), `created_at`, `updated_at`.

**`person`** and **`book_person`** (`book_id`, `person_id`, `role` = author | narrator, `ordinal`). Contributors are normalized because narrators matter far more in audiobooks than illustrators do in manga: users filter by narrator, follow narrators, and use narrator to tell editions apart.

**`chapter`**: `id`, `book_id`, `key` (unique with `book_id`), `title`, `source_index`, `group_name`, `duration_ms`, `published_at`, `is_listened`, `listened_at`, `last_position_ms` (chapter-relative), `removed_from_source` (soft delete), `created_at`, `updated_at`.

**`media_file`**: one row per physical audio file known for a book. `id`, `book_id`, `file_key` (unique with `book_id`), `format`, `duration_ms`, `size_bytes`, `embedded_markers` (JSON, from probing), `local_path` (non-null once downloaded), `downloaded_at`.

**`chapter_segment`**: the persisted *layout* of each chapter. `chapter_id`, `ordinal`, `media_file_id`, `start_ms`, `end_ms`. URLs are deliberately not stored here; they're ephemeral. The layout and durations are stored so that the timeline, offline playback, and progress math all work without calling the extension.

**`playback_state`**: one row per started book, the source of truth for Continue Listening. `book_id`, `chapter_id`, `chapter_position_ms`, `global_position_ms` (derived, cached for sorting and display), `updated_at`, `device_id`.

**`listening_session`**: `book_id`, `chapter_id`, `started_at`, `ended_at`, `start_global_ms`, `end_global_ms`, `speed`, `device_id`. This powers history and statistics (time listened, streaks, per-book totals).

**`bookmark`**: `book_id`, `chapter_id`, `position_ms`, `title`, `note`, `created_at`.

**`category`** (`name`, `sort_order`, `flags` for per-category sort, filter, and display mode) and **`book_category`** (many-to-many, as in Mihon).

**`smart_collection`**: `name`, `sort_order`, `rules` (a JSON predicate such as "narrator is X", "downloaded", "unfinished", "genre contains Y"), compiled to SQL by a small query builder. Series groupings are virtual collections derived from `series_name`.

**`repository`** (`url`, `name`, `public_key`, `fingerprint`, `etag`, `last_fetched_at`), **`extension`** (`id`, `repository_id`, `version`, `version_code`, `api_version`, `install_path`, `status` = active | obsolete | untrusted | revoked | unhealthy, `installed_at`), **`source`** (`id` as the stable hash, `extension_id` nullable for built-ins, `key`, `name`, `lang`, `content_rating`, `is_enabled`, `is_pinned`, `last_used_at`), and **`extension_preference`** (`extension_id`, `key`, `value`; secrets live in platform secure storage instead).

**`download_task`** is described in Section 5.

**`book_fts`**, an FTS5 virtual table over title, authors, narrators, and series, powers instant library search.

Indexes cover the hot paths: library listing (`in_library`, `date_added`), chapter lists (`book_id`, `source_index`), the download queue (`state`, `priority`), and history (`started_at`).

App preferences that aren't user data (theme, skip intervals, and so on) live in a typed settings store backed by `shared_preferences`, with keys defined in one place. Those that should survive a restore are included in backups explicitly.

### 4.4 Identity and merge rules

A book's global identity is `(source_id, key)`; its local integer ID is a surrogate used only for joins.

When details are refreshed, source-provided fields overwrite stored values except for fields listed in `user_overrides`, and a custom cover always survives.

Chapter synchronization matches chapters by key. New keys are inserted. Keys that disappear are soft-deleted, and kept indefinitely if they carry progress, bookmarks, or downloads. Changed ordering updates `source_index`. When a key changes but the title and index match and the duration is within a small tolerance, the chapter is treated as renamed and its progress is carried over. Sources shuffling their URL schemes is one of the most common ways Mihon users lose progress, and this soft matching exists to prevent that.

### 4.5 The Timeline

The Timeline is the central audiobook abstraction. It is not stored; it is computed on demand from a book's chapters, chapter segments, and media file durations.

```
Files:     [ part1.mp3 · 40m        ][ part2.mp3 · 35m      ][ part3.mp3 · 50m          ]
Chapters:  [ Ch 1  ][     Ch 2     ][ Ch 3 ][    Ch 4      ][ Ch 5 ][     Ch 6          ]
Global:    0 ─────────────────────────────────────────────────────────────────── 2h 05m
```

It converts in every direction between a book-global position, a `(chapter, offset)` pair, and a `(file, offset)` pair. The player engine thinks only in files. The UI and progress think in chapters. The scrubber, statistics, and "time remaining" think in global time.

Progress is stored **chapter-relative** as the source of truth, with the global position derived. This matters because durations are often unknown until a file has been probed. If a chapter early in the book turns out to be 12 seconds longer than the source claimed, every global position after it shifts, but a chapter-relative position stays correct. Durations are estimated until known, refined as files load, and persisted once learned.

When a book has a single source chapter whose file carries embedded markers, the Timeline presents the markers as virtual chapters for navigation and display, while progress and bookmarks remain anchored to the source chapter plus an offset.

A chapter counts as listened when its position reaches its duration minus the larger of 30 seconds or 3 percent, which avoids chapters stuck at "99%" because of closing credits. A book is finished when its last chapter is listened.

---

## 5. Local Storage and Download Management

### 5.1 Storage locations

| Data | Android | Windows | iOS (later) |
|---|---|---|---|
| Database | App-internal storage | Per-user local app-data folder | Application Support |
| Installed extensions | App-internal storage | Local app-data folder | Application Support |
| Downloads | App-specific storage by default; a user-chosen folder as a later option | User-chosen folder, defaulting to a folder under the user's Music directory | Application Support, excluded from iCloud backup |
| Covers | Library covers internal; browse covers in cache | Same pattern in app data and cache | Same pattern |
| Automatic backups | User-chosen folder (Storage Access Framework) | User-chosen folder | Files-visible folder plus a user-chosen folder |
| Local-source imports | User-chosen folders (Storage Access Framework) | Any folder | Files-visible `Import` folder plus bookmarked folders |

All path decisions go through one `StorageLocations` adapter built on `path_provider`, so no feature ever constructs a platform path itself.

Download paths use IDs rather than titles, as in v0.2: no filename sanitization problems, and renaming a book never moves gigabytes of files.

**Reinstall means data loss on Android, just as re-signing does on iOS.** Android deletes an app's private and app-specific storage when the app is uninstalled. Normal updates keep it, but an uninstall-and-reinstall (for example after a signing-key mismatch, or a user clearing things out) loses the library, progress, and downloads. That is why automatic backups go to a folder the user picks outside the app from Phase 1 onward, and why the app offers to restore from that folder on a fresh install. Android's own cloud backup is configured to exclude downloads and caches.

On Windows, users expect to see their files, so the download folder is visible and configurable, while the database and extensions stay in app data.

### 5.2 Download engine components

The **queue** is the `download_task` table, which is the source of truth. Tasks are per `media_file`, not per chapter, so a shared M4B file is downloaded exactly once no matter how many chapters reference it. Downloading "a chapter" enqueues the files its segments reference; downloading "a book" enqueues all of its files.

**`download_task`** columns: `id`, `media_file_id`, `state`, `priority`, `bytes_done`, `bytes_total`, `request_snapshot` (resolved URL and headers), `expires_at`, `attempts`, `last_error`, `transport_task_id`, `created_at`.

The **scheduler** chooses what runs next within limits: a global concurrency cap (default 3), a per-source cap (default 1 to 2, which extensions may lower), the user's network policy (Wi-Fi only or cellular allowed on Android, respecting metered connections), and a free-space floor below which downloading stops.

The **resolver** calls the extension's `resolveMedia` with `purpose: 'download'` and stores the resulting request snapshot and its expiry.

The **transport** is an interface. Its implementation uses `background_downloader`, which delegates to WorkManager on Android (with an optional foreground mode for long transfers), to background `URLSession` on iOS, and runs in-process on desktop. The database remains the source of truth; the plugin is just the mechanism that moves bytes.

The **post-processor** validates each completed file (status code, a content type that isn't HTML, a plausible size, and a magic-byte check, because many sites return an HTML error page with a 200 status), probes it for duration, format, and embedded chapter markers, moves it atomically to its final path, and updates the database.

The **reconciler** runs at launch and matches the transport's live tasks to database rows, repairing any drift. A periodic sweep removes orphaned files that have no row and rows whose files have gone missing.

### 5.3 State machine

```
queued ──► resolving ──► waiting(network | storage | slot) ──► downloading ⇄ paused
                                                                   │
                                  403 / 410 / expired ◄────────────┤
                                  → needsResolve → resolving       ▼
                                                              processing ──► completed
any state ──► failed(retryable) ──backoff──► queued
any state ──► failed(permanent)       any state ──► cancelled
```

### 5.4 Expiring URLs and background limits, per platform

Many sources return signed URLs that expire within minutes, and resolving a URL requires running extension code. Resolution is therefore **just in time** on every platform: URLs are resolved only when a file is about to start, with a small lookahead, never for a whole book at enqueue time. A 403 or 410 moves a task to `needsResolve` instead of failing it.

**Android** is the most workable mobile platform for this. While downloads are active, the app can run a visible foreground service with a progress notification, which keeps the process alive, and with it the extension runtime, so each next file can be resolved and started as the previous one finishes. Two platform rules shape this. Android 14 and later require foreground services to declare their type. Android 15 limits data-sync foreground services to about six hours in any 24-hour period, so very large queues must pause gracefully and continue later. Phase 0 checks exactly which mechanism `background_downloader` uses and how it behaves at these limits; Android's user-initiated data transfer jobs are the alternative if needed. Some manufacturers also kill background apps aggressively, so the app offers to request an exemption from battery optimization, which is permitted outside the Play Store.

**Windows** imposes no background restrictions while the app is running. Downloads pause when the app exits and resume on the next launch; minimize-to-tray keeps them going with the window closed.

**iOS** is the most restrictive; the chained-on-wake approach from v0.2 is preserved in Appendix A.

### 5.5 Retries and protection against bans

Retries use exponential backoff with jitter, respect `Retry-After`, and give up after five attempts. A per-source circuit breaker pauses a source's queue after repeated consecutive failures and notifies the user, which avoids hammering a site that has started blocking requests.

### 5.6 Storage management

The Downloads screen shows total usage, per-book sizes, and per-chapter delete. Automatic policies include deleting finished chapters (immediately, after a delay, or never), "keep the next N chapters downloaded" while listening, and automatically downloading new chapters for library books on unmetered connections. Free space is checked before each file starts.

### 5.7 Offline-first behavior

The library, details, chapter lists, covers, progress, bookmarks, and history are all local. A downloaded chapter plays without ever touching its extension, because its layout and files are persisted. The network is needed only to browse, search, refresh, stream, and download.

Library updates (checking library books for new chapters) run as a periodic WorkManager job on Android, on launch and periodically while running on Windows, and on a best-effort basis on iOS, always subject to per-source rate limits. Results feed the Home screen's updates section.

---

## 6. Audio Player Subsystem

### 6.1 Components

```
      Flutter UI: MiniPlayer · PlayerScreen · DesktopPlayerBar · ChapterList · Sheets
                              │ watches PlayerState (Riverpod)
                    ┌─────────▼───────────┐
                    │ PlaybackCoordinator  │ pure Dart: session, Timeline, commands
                    └─┬──────┬──────┬─────┬┘
       ┌──────────────┘      │      │     └────────────────┐
┌──────▼────────┐ ┌──────────▼───┐ ┌▼─────────────┐ ┌──────▼──────────────┐
│PlaybackEngine │ │MediaResolver │ │ProgressStore │ │ MediaSessionBridge  │
│ (just_audio)  │ │local · cache │ │throttled     │ │ audio_service /     │
│               │ │· extension   │ │writes        │ │ Windows SMTC        │
└──────┬────────┘ └──────────────┘ └──────────────┘ └─────────────────────┘
┌──────▼─────────┐ ┌──────────────┐ ┌────────────────────┐
│AudioFocusPolicy│ │  SleepTimer  │ │ InterruptionPolicy │
│(audio_session) │ │              │ │                    │
└────────────────┘ └──────────────┘ └────────────────────┘
```

The **`PlaybackCoordinator`** is the brain and is pure Dart. It owns the current session (book, Timeline, position), translates user and system commands into engine operations, publishes one `PlayerState` that every piece of UI watches, and coordinates the other components.

The **`PlaybackEngine`** interface is deliberately dumb: load a list of file items, play, pause, seek to an offset in an item, set speed, and emit an event stream (position, item changes, buffering, errors, completion). It knows nothing about books or chapters, so the coordinator can be tested fully against a fake engine.

### 6.2 Engine choice

The first implementation is built on `just_audio`, which wraps each platform's strongest player: ExoPlayer (Media3) on Android, AVQueuePlayer on iOS, and an mpv-based backend (via `just_audio_media_kit`) on Windows. All three handle progressive streaming with range requests (essential for 1 GB M4B files), HLS, playlists with preloading for near-gapless transitions, and speed changes with pitch preserved. Using `media_kit` directly on every platform is the fallback, and the engine interface makes that swap cheap.

As in v0.2, engine queue items are **files, not chapters**. Chapters are an overlay computed by the Timeline. A book that is one M4B plays as one item and "next chapter" becomes a seek; a chapter spanning three files is three items; non-contiguous oddities use clipped sources with start and end offsets.

### 6.3 Media resolution and request headers

The resolver tries, in order: a downloaded local file; a cached resolution that hasn't expired; and a fresh `resolveMedia(purpose: 'stream')` call to the extension.

Many sources require specific headers (a referer, a token, cookies). `just_audio` accepts per-source headers, though the mechanism differs by backend; Phase 0 verifies header support on each one. The fallback, if any backend falls short, is a small loopback HTTP proxy inside the app. The player requests a local URL; the proxy fetches the real URL with the right headers, handles range requests, and on a 403 re-resolves the URL through the extension and continues. That one mechanism would work identically on every platform. Either way, a stream error triggers one transparent re-resolve and a reload at the same position before the user ever sees an error.

### 6.4 Progress and resume

Progress is written through one path, the `ProgressStore`: throttled to every five seconds during playback, and immediately on pause, seek, chapter change, interruption, and when the app moves to the background. At most a few seconds are lost if the app is killed. Each play-to-pause span is recorded as a `listening_session` for history and statistics.

Resuming applies **smart rewind**: no rewind after a short pause, a few seconds after a longer one, and up to 30 seconds after a long break (configurable). Playback speed is remembered per book.

### 6.5 Controls

**Seeking** offers separately configurable back and forward intervals (10, 15, 30, 45, or 60 seconds), previous/next chapter, and a scrubber that is chapter-relative by default with a whole-book option.

**Speed** ranges from 0.5× to 3.5× in 0.05× steps, with presets, and pitch is preserved on every backend.

**The sleep timer** offers presets, a custom duration, and "end of chapter", fades out over the final 15 to 30 seconds, and applies a small automatic rewind when playback resumes after a timer stop. It runs as a normal Dart timer in the main isolate. That works in the background because active playback keeps the process alive on every platform: through a foreground service on Android, the audio background mode on iOS, and simply as a running process on Windows. Shake-to-extend is available on phones.

**Platform integration:**

| Concern | Android | Windows | iOS (later) |
|---|---|---|---|
| Background playback | `audio_service` foreground service of type media playback | Normal process; optional minimize-to-tray | Audio background mode |
| System controls | Media session: notification, lock screen, Bluetooth buttons, watches | System Media Transport Controls: media keys and the volume flyout, through a Windows SMTC plugin | Now Playing and remote commands |
| Audio focus and interruptions | Speech content type, so navigation prompts pause the book instead of talking over it; pause on "becoming noisy" (headphones unplugged) | Not applicable | `.spokenAudio` session mode; pause on route change |
| Car integration | Android Auto through `audio_service`'s media browsing (sideloaded apps require Android Auto's "unknown sources" developer setting) | Not applicable | CarPlay is unavailable to sideloaded builds |
| Skip silence | Supported natively by ExoPlayer and exposed by `just_audio` | Later | Later |

Download progress notifications require the Android 13+ notification permission, which the app requests only when the user first downloads something.

### 6.6 Later enhancements

Cross-platform skip-silence and voice boost (which need custom audio processing outside Android), an equalizer, bookmark clips, an Android home-screen widget, Wear OS controls beyond what the media session provides, Windows taskbar thumbnail buttons, and Siri/Shortcuts integration once iOS is built.

---

## 7. Legal, Distribution, and Technical Challenges

### 7.1 Legal

*I'm not a lawyer, and this section is an engineering risk assessment rather than legal advice. Before public launch, a short consultation with an IP lawyer familiar with app distribution would be money well spent.*

**Piracy and secondary liability.** Tachiyomi's shutdown is the direct precedent, and sideloading does nothing to reduce this risk: Tachiyomi was never distributed through Google Play, and the pressure landed on the project and its hosting rather than on a store. With Apple out of the picture, takedown notices against your GitHub repositories and releases become the realistic enforcement path. Architectural neutrality ("the app doesn't host anything") did not protect the project once the same organization maintained extensions that pointed at unauthorized content. The protective measures are behavioral as much as technical: the app and its documentation never list or recommend third-party repositories; marketing never shows copyrighted catalogs; and there is a published terms-of-use page and a takedown contact.

**DRM circumvention.** The app must never support removing or bypassing DRM (Audible AAX/AAXC, OverDrive/Libby, Apple Books). Anti-circumvention laws such as DMCA §1201 in the US and their EU equivalents apply independently of whether any infringement follows. This belongs in the extension policy, and the host API must not include anything purpose-built for it.

**Trademarks.** Don't use "Mihon", "Tachiyomi", "Aniyomi", or retailer brands in the app's name, icon, or store listing.

**Licensing of your own code.** Mihon and Aniyomi are Apache-2.0 licensed, so any code you port (as opposed to ideas you adopt) must keep its notices. The app itself is Apache-2.0, the same license as Mihon and Mangayomi, which keeps porting clean and avoids the long-running friction between GPL licensing and Apple's App Store terms should an iOS store edition ever be considered.

**Jurisdiction.** Although you're based in Lebanon, hosting releases and code on GitHub puts the project within reach of US DMCA takedown processes regardless of local law.

**Privacy.** Collect nothing by default. Any crash reporting is opt-in and scrubbed of library contents.

### 7.2 Distribution

Every platform is sideload-first. None of the major app stores is a target, because their intellectual-property policies conflict with an open extension ecosystem in the same way the App Store's do.

**Android.** Release APKs (per-architecture splits plus a universal build) are attached to GitHub Releases. The app includes an in-app updater that checks the release feed, downloads the new APK, and hands it to the system installer. This is allowed outside the Play Store and also works with tools like Obtainium. Community repositories such as IzzyOnDroid or F-Droid are possible later. Two identifiers are permanent. The application ID can never change without becoming a different app. The release signing keystore must be backed up in at least two safe places: if it is lost, no update can ever be installed over existing copies, and users would have to uninstall, losing their data (Section 5.1).

**Android developer verification.** Google's developer verification program changes sideloading. Enforcement begins on September 30, 2026 in Brazil, Indonesia, Singapore, and Thailand, and expands globally in 2027. A verified personal account requires identity verification and a one-time fee of about $25. A free limited-distribution account allows installs on up to 20 devices without a government ID, which suits Phases 0 through 2. Apps from unregistered developers can still be installed through an "advanced" install flow with a waiting period, or through ADB, but that is a real barrier for ordinary users. The recommendation is to register as a verified developer and register the application ID and signing key before the global rollout. The trade-off is that this ties your legal identity to the app in Google's records, which is one more reason the legal practices in Section 7.1 matter.

**Windows.** Each release ships as a portable zip and an installer (Inno Setup or MSIX). The installer also registers the `kikuyomi://` protocol for deep links. Unsigned executables trigger SmartScreen warnings until they build reputation. Open-source projects can obtain free code signing through programs such as the SignPath Foundation; that is worth pursuing before 1.0. The same in-app update checker reads GitHub Releases, and a winget manifest can come later.

**iOS** is covered in Appendix A.

**Release pipeline.** A tagged commit triggers CI: tests, Android APKs on Linux, Windows builds on a Windows runner, and the iOS canary IPA on macOS. It then publishes a GitHub Release and updates the release feeds the in-app updaters read. The app repository, the official extensions repository, and anything third-party stay clearly separate.

A `DistributionPolicy` seam is retained, as in v0.2, so a store edition on any platform remains possible without refactoring.

### 7.3 Technical challenges

| Challenge | Impact | Mitigation |
|---|---|---|
| Maturity and maintenance of QuickJS bindings for Flutter | High | Phase 0 evaluation against explicit criteria; Rust `rquickjs` fallback; engine behind an interface |
| A native crash inside the JS engine takes down the app | Medium | Mature binding, contract tests on every release, small host API, memory limits |
| Anti-bot protection (Cloudflare, JS challenges, captchas); Dart's default HTTP client has a TLS fingerprint that differs from browsers and can draw extra blocks | High for web sources | Platform-native HTTP clients where available (Cronet on Android, URLSession on iOS); an interactive WebView challenge through `flutter_inappwebview` with cookie sync; one consistent User-Agent; rate limits. Some sites won't work |
| Expiring signed URLs | High | Just-in-time resolution, expiry tracking, transparent re-resolve for streams, `needsResolve` state for downloads |
| Request headers for streaming differ by audio backend | Medium | Verified per backend in Phase 0; loopback proxy fallback |
| Android background limits, foreground-service rules, and manufacturer battery killers | High | Typed foreground services, graceful handling of the data-sync time limit, battery-optimization exemption prompt, real-device testing |
| Plugin gaps on Windows (media controls, WebView, background transport) | Medium | Everything behind adapters; each checked in Phase 0; known alternatives exist for SMTC and WebView |
| Embedded M4B chapter extraction isn't provided by the audio plugins | Medium | Small MP4 chapter parser in Dart, or a Rust crate |
| Audio format coverage differs by platform | Low on Android and Windows, medium on iOS | ExoPlayer and the mpv backend cover almost everything, including Ogg/Opus; AVFoundation is narrower. A per-platform capability matrix marks unsupported files clearly |
| VBR MP3 seek and duration imprecision | Medium | Chapter-relative progress, backend precise-seek options for local files, prefer CBR or M4B variants when offered |
| Unknown durations before loading | Medium | Estimated, self-refining Timeline; persist learned durations |
| Data loss on Android reinstall or iOS re-sign | High for users | Automatic backups to a user-chosen folder and restore on first launch, from Phase 1 |
| Unstable chapter keys across source changes | Medium | Soft matching; `versionId` migrations |
| Schema and backup evolution | Medium | Drift schema snapshots with migration tests; protobuf field-number discipline |
| Global search across hundreds of sources | Medium | Bounded concurrency (around five), per-source timeouts, pinned sources first, incremental results, cancellation |
| iOS regressions go unnoticed without a Mac | Medium | iOS canary IPA built in CI from Phase 0; periodic sideloaded smoke tests on the iPhone |
| V8 (Node) vs QuickJS (app) differences for extension authors | Low | SDK test runner executes extensions in QuickJS compiled to WebAssembly under Node |
| Isolate messaging overhead | Low | Transferable byte buffers; coarse-grained calls |

---

## 8. Roadmap

Estimates assume one developer working part-time (roughly 15 to 20 hours a week) and will be revised after Phase 0. Each phase ends with something usable, and the riskiest unknowns are tackled first.

| Phase | Goal | Scope | Exit criteria | Est. |
|---|---|---|---|---|
| **0. Environment and spikes** | Prove the hard pillars on the real toolchain | Dev environment (`flutter doctor` clean for Android and Windows); CI skeleton producing an Android APK, a Windows build, and an unsigned iOS IPA. Spikes: (a) QuickJS binding selection against the criteria in 3.1, plus HTML selector coverage in the Dart parser; (b) playback with `just_audio` and `audio_service` on Android and Windows: multi-file book, headers, speed, notification or SMTC controls, background, audio focus; (c) downloads with `background_downloader` on Android, including expiring URLs, process kill, and foreground-service limits; and on Windows; (d) M4B chapter extraction; (e) sideload the iOS canary onto your iPhone and confirm it launches and plays audio in the background. Write the ADRs | Everything works on Android and Windows; the iOS canary runs; measurements recorded; ADRs approved | 3–4 wks |
| **1. Foundation + local player** | A genuinely useful local audiobook player on Android and Windows | Workspace and package structure, Drift schema v1 with migration tests, domain entities, Timeline, design system and adaptive shell, Local source (Android folder picker, Windows folders and drag-and-drop, tags, M4B chapters), library, book details, full player (play/pause, seek, speed, sleep timer, background, system media controls, remembered position), progress, Continue Listening, automatic backups to a user-chosen folder with restore on fresh install | **M1:** you use it daily on your PC and on an Android device, and an uninstall-reinstall loses nothing | 5–7 wks |
| **2. Extension system v1 + first public release** | Content from installable sources | SourceAPI 1.0, TypeScript SDK and CLI, QuickJS runtime with worker isolates and bridges, ExtensionManager (repositories, install/update/uninstall, signatures, trust), Browse, per-source search, extension-backed details and chapters, streaming with re-resolve, LibriVox and Internet Archive extensions in the official repository, GitHub Releases for Android and Windows, in-app update checker, Android developer account (limited distribution or verified) | **M2 = MVP:** browse → details → stream from an installed extension, end to end, installed by a tester from a public release | 6–8 wks |
| **3. Offline** | Listen anywhere | Download engine on Android and Windows, queue UI, pause/resume, per-chapter and whole-book downloads, storage management, auto-delete, "keep next N", notifications, battery-optimization guidance, airplane-mode test pass, diagnostics export | **M3:** a full book downloaded and finished with no network | 4–5 wks |
| **4. Library power features** | Feature-complete beta | Categories with per-category settings, smart collections, series grouping, filtering and sorting, full-text library search, history and stats, bookmarks, manual backup/restore with selective restore and retention, metadata editing, library updates and Home feed, global search, source migration | **M4:** public beta | 4–6 wks |
| **5. Ecosystem and robustness** | Ready for third-party extension authors | Source settings and login, WebView challenge flow, platform-native HTTP clients, extension health and logs, developer mode (LAN repository, live reload), SDK documentation, template repository, contract test suite, synthetic 300-source load test, revocation and obsolescence handling, built-in Audiobookshelf and OPDS | External authors can ship an extension using only the docs | 4–6 wks |
| **6. Production hardening** | 1.0 on Android and Windows | Accessibility (TalkBack, Windows Narrator, text scaling), localization including RTL, Android Auto, sync backends (folder, WebDAV, Audiobookshelf), trackers (Audiobookshelf, Hardcover), skip-silence on Android, optional home-screen widget, desktop polish (tray, shortcuts, window state), Windows installer and code signing, verified Android developer registration completed ahead of the 2027 global rollout | **M5:** 1.0 released | 5–7 wks |
| **7. iOS target** | iOS release, once a Mac is available | iOS adapter configuration and fixes (Appendix A), on-device QA, AltStore/SideStore feed | iOS build in the release pipeline | 3–6 wks |
| **8. Optional** | Wider reach | macOS and Linux builds; store editions through `DistributionPolicy` | As needed | As needed |

In total that is roughly eight to ten months part-time to 1.0 on Android and Windows, with the MVP (M2) reachable in about four months. After 1.0, the extension API evolves through additive minor versions, with any major version preceded by a published deprecation window.

---

## 9. Decisions for Approval

| # | Decision | Recommendation | Main alternative |
|---|---|---|---|
| 1 | Framework | Flutter, Android and Windows first, iOS planned | Kotlin Multiplatform with Compose Multiplatform |
| 2 | Extension runtime | JavaScript (authored in TypeScript) in embedded QuickJS; binding chosen in Phase 0 | Dart interpreter; Android-only APK extensions |
| 3 | Built-in sources | Local, Audiobookshelf, OPDS as native code; LibriVox and Internet Archive as JS in an official repository | No official repository |
| 4 | Persistence | Drift (SQLite) | Isar, sqflite |
| 5 | State management and DI | Riverpod | Bloc |
| 6 | Navigation | go_router | auto_route |
| 7 | Playback | `just_audio` + `audio_service` + `audio_session`, behind an engine interface | `media_kit` everywhere |
| 8 | Download transport | `background_downloader`, behind a transport interface | Custom per-platform implementations |
| 9 | Backup format | Gzipped protobuf, automatic, to a user-chosen folder | Gzipped JSON |
| 10 | Categories vs collections | Categories are manual, many-to-many library tabs; collections are rule-based smart groups plus automatic series grouping | Treat both as manual groupings |
| 11 | Distribution | Sideload-first: GitHub Releases for Android and Windows with in-app updates; AltStore/SideStore for iOS later; register as a verified Android developer | Store distribution |
| 12 | License | **Decided:** Apache-2.0 | — |
| 13 | Sync | Pluggable backends (folder, WebDAV, Audiobookshelf) | A single cloud provider |
| 14 | Minimum versions | Android 8.0 (API 26), Windows 10, iOS 17 | Lower Android minimum |
| 15 | Name and application ID | **Decided, final:** Kikuyomi; application ID and Android namespace `io.github.kikuyomiapp.kikuyomi`. The `kikuyomi` GitHub organization name was already taken, so the project owns the `kikuyomiapp` organization and the identifiers follow it. These identifiers are locked: the Flutter app package therefore keeps the bare pubspec name `kikuyomi`, since its name feeds them | — |

These decisions are approved. The next step is Phase 0: environment setup, the CI skeleton, the spikes, and the ADRs that record these decisions.

---

## Appendix A: iOS Target Notes

These findings from v0.2 apply when the iOS target is built in Phase 7. Most of them become configuration in the platform adapters rather than new architecture.

**Building.** iOS builds require macOS and Xcode. Until a Mac is available, CI builds an unsigned IPA on a macOS runner, and you install it from Windows with Sideloadly or AltServer.

**Distribution.** Ship through an AltStore-format source feed that works in both AltStore and SideStore. Free Apple IDs sign apps for 7 days and allow 3 active sideloaded apps; LiveContainer lets users exceed that, so test inside it too. Avoid enterprise-certificate signing services, whose shared certificates get revoked in waves.

**Re-signing can wipe data.** Re-signing under a different account or tool can change the bundle identifier, which gives the app a new, empty container. The automatic external backups from Phase 1 already cover this. Never hardcode bundle or app-group identifiers.

**Unavailable to sideloaded builds.** CloudKit, CarPlay, and remote push all need entitlements tied to a developer team, which a re-signed build can't carry. Keychain items are also team-scoped, so stored logins may need re-entry after a re-sign.

**Audio session.** Use the `.playback` category, `.spokenAudio` mode, and long-form route sharing (configured through `audio_session`), plus the audio background mode. Handle interruptions and pause on route changes. The lock screen shows either skip-interval buttons or previous/next-track buttons, not both; default to skip intervals.

**File protection.** Use `completeUntilFirstUserAuthentication` for the database and downloads; the stricter class makes files unreadable shortly after the phone locks, breaking playback mid-chapter. Store downloads in Application Support and exclude them from iCloud backup.

**Background downloads.** `background_downloader` uses background `URLSession`, but extension code cannot run while the app is suspended. Resolve just in time, chain the next file when the system wakes the app for session events, and use `needsResolve` for expired URLs. Be honest in the UI that queued items may continue only when the app is open.

**Headers.** AVPlayer has no public API for arbitrary request headers, so rely on `just_audio`'s mechanism or the loopback proxy from 6.3.

**Formats.** AVFoundation covers MP3, AAC, M4A/M4B, ALAC, FLAC, and WAV; Ogg-contained Vorbis and Opus have historically been a gap. The capability matrix handles this.

**Crash visibility.** There are no App Store Connect crash reports for sideloaded installs; collect MetricKit diagnostics and offer the same "share diagnostics" export as other platforms.

**If an App Store edition is ever wanted.** QuickJS runs as an interpreter, which is fine for sideloaded builds. A store edition would need to satisfy guidelines 2.5.2 and 4.7 (plug-ins are allowed, but the developer is responsible for all of them, including their legal compliance), 4.7.2 (no exposing native APIs to plug-ins), and 5.2.3 (no downloading media from third-party sources without authorization). The `ScriptEngine` interface allows switching to JavaScriptCore on Apple platforms if review ever requires it.
