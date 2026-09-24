# Status

Where Kikuyomi stands: what exists, what has been exercised for real, and what comes next.

`CLAUDE.md` carries the rules, the layout and the commands — the things that are true on every task.
This file carries the things that change every week, so that the guide stays short and this stays
honest. The approved design is `docs/architecture.md` (v0.3); individual decisions are in
`docs/adr/`; `spikes/README.md` carries each spike's status and what is blocking it.

## Phases

**Phase 0** is environment setup, the CI skeleton and the spikes. Spikes live in `spikes/` and are
throwaway: each answers one question on the real toolchain and produces an ADR. One has outlived
that purpose and is kept — see [the probe](#the-probe) below.

**Phase 1**, the app's first vertical slice, began ahead of Phase 0's Android items.

**Phase 2**, extensions, began with the contract and is where the work is now.

All fifteen decisions in §9 of the architecture document have ADRs, and all fifteen are Accepted. Two
more decisions have been made since: ADR-0016, the contract, and ADR-0017, installing an extension
from a folder.

## The packages

Fourteen under `packages/`, all unit tested. Pure-Dart unless noted.

### `source_api` — the extension contract

The Dart mirror of SourceAPI 1.0 (ADR-0016, `docs/source-api-1.0.md`). Treat it as a versioned
public API: changes need asking first, and minor versions are additive only.

- `apiVersion`, and the check that says whether an extension targeting a version is supported, needs
  a newer app, or is obsolete.
- The immutable types a source hands the app, and the sealed `SourceException` family.
- `ContentSource`, whose three optional methods are declared in a capability set the caller checks.
- The Limits table as named constants.
- `DomainAllowlist`, which holds every URL an extension fetches or hands over to the domains its
  manifest declared.
- `PlainDataDecoder`, which turns an extension's plain data into those types and fails a call as
  `Parse`, naming the field that broke a rule; and the encoders for what the host passes in, a saved
  search included.

Nothing in it runs JavaScript. That is `source_runtime`'s work.

### `source_runtime` — the extension runtime

- `ScriptEngine`, the one interface ADR-0001 keeps as its escape hatch: a runtime per extension,
  evaluating its bundle, calling a named function with plain data, exposing host functions to it,
  taking a memory limit and arming a deadline for one call.
- §3.5's prelude, which is the whole environment an extension runs in, since QuickJS is ES2020 and
  nothing more: `setTimeout`, `clearTimeout`, `TextEncoder`, `TextDecoder`, `URL` and
  `URLSearchParams` (parsed by the host, with the parser that checks them), `atob`, `btoa`, a
  `console` that goes where the log does, and the `kikuyomi` object the host API is reached through
  — all behind one host function the prelude captures and hides.
- The protocol that loads the host's facts, the prelude and the bundle, finds the default export in
  whichever shape a bundler leaves it, and calls a source's methods so that nothing is thrown across
  the boundary and an error's kind survives as data.
- `JsSourceAdapter`: `ContentSource` over an extension, so nothing above can tell an extension from
  a built-in source. It sits over a runtime in this isolate or one confined to a worker; both are an
  `ExtensionCalls`.
- The host bridges of §3.5 — `log` (leveled, rate limited, into a console the app provides), `host`,
  `storage` (namespaced per extension, capped at 1 MB), `crypto` (hashes, HMAC, base64 and AES, for
  reading a site's own responses and never media, §7.1), `html` (`package:html`, refusing the six
  selectors SourceAPI 1.0 names rather than answering wrongly) and `http`.
- The worker isolate a runtime is confined to (§3.6), with `html` and `crypto` inside it and `http`,
  `storage` and `log` proxied back to the isolate that started it. One worker per extension; the
  place a pool would go is written down.

### `networking`

The app's one transport and each extension's view of it: a cookie jar and rate limiters of its own,
the host's User-Agent, timeouts, a 10 MB body cap, and redirects followed one hop at a time so every
hop can be held to the extension's domains. The rate limiter is a leaky bucket with a burst
allowance, so work that comes in bursts and then stops is not charged a flat gap per request.

### `extension_manager`

`manifest.json` — id, version, versionCode, apiVersion, minAppVersion, domains, capabilities and
sources — read as strictly as a result is, with the contract's compatibility check and §3.7's
source id.

And the package around that manifest (ADR-0017): `ExtensionFiles`, which is wherever a package's bytes
are — the app's assets, a folder on the device, the app's own copy of an installed one; one reader over
it that checks the manifest, the `main.js` and, when asked, the SHA-256 the manifest names; and
`ExtensionInstallFolder`, which keeps the app's copy under `<id>/<versionCode>`, writing it under a
partial name so a half-finished install never looks finished.

### `domain`

The Timeline; the `Clock`, `PlaybackStore` and `MediaResolver` interfaces; the `ListeningSession`
entity; the types backups share with `data` (the library snapshot, the restore plan, and the
interfaces that read and restore the library); §4.3's typed settings store (`SettingsStore`, with
every key in `AppSettings`); `UserFolders`, the interface to folders the user chooses outside the
app's storage; and §7.3's capability matrix — `AudioFormat`, `PlayableFormats`, one platform's row
of it, and `UnplayableFormatException`, which names the formats a refused book is in.

### `playback`

`PlaybackCoordinator` and the engine contract it drives: the progress-write rules, smart rewind, the
sleep timer, listening-session recording, recording each chapter listened as progress reaches
§4.5's threshold, a finished state that follows what is stored, §6.5's interruption rules, refining
a file's estimated duration once the engine reports the real one (§4.5), and the sync that keeps the
system's media controls in step.

A queue item may arrive unresolved, for the engine to resolve when it first opens it — see
[streaming](#streaming) below.

### `data`

Drift schema version 2. Version 2 adds the two tables installing an extension needs — `extension` and
`extension_preference` (§4.3) — and touches nothing version 1 wrote. `sources.extension_id`
deliberately stays a plain id rather than becoming a foreign key, because §3.9 has a source outlive
the extension it came from (ADR-0017).

- The §4.4 chapter-sync, book-details and credits merges. Chapter sync carries a chapter's release
  time and group heading as well as its title and duration.
- Loading a book's Timeline for playback, and the Drift-backed `PlaybackStore`.
- Importing local books of one file or of several, and the import folder that keeps picked files.
- The watched read models behind Continue Listening and a book's details, which read each chapter's
  recorded listened state, work out a single file's markers from the listener's position, and share
  one test of a finished book.
- Marking chapters and whole books listened or not by hand; a one-time backfill of listened state
  from positions saved before it was recorded; taking a book out of the library.
- What extensions are installed, their versions and where they came from; and each extension's own
  `storage`, which was in memory until this table arrived.
- Keeping a book's cover in the covers folder, including finding the covers of local books added
  before covers were kept, and of source books still waiting for theirs.
- For books from a source: the credits merge §4.4 implied (authors and narrators into `People` and
  `BookPeople` with role and ordinal, a name repeated within a role kept once, a role the source
  left empty not decided at all); the mapping from the contract's types onto those merges;
  `saveSourceBook`, which writes details, credits, chapters and the estimated layout in one
  transaction; and `SourceMediaResolver`, which resolves a chapter through its source just in time
  (§6.3), honours `expiresAt`, re-resolves on the coordinator's retry, hands the engine the headers
  a site needs, stores the layout while keeping URLs out of the database (§4.3), and sends a file
  already on the device to the local resolver.

### `sources_builtin`

The M4B, MP3, FLAC and Ogg readers, which also read embedded cover art. One reader of Vorbis
comments serves FLAC and Ogg, `CHAPTERnnn` chapters and `METADATA_BLOCK_PICTURE` covers included.
The Ogg reader tells Vorbis from Opus by the stream and refuses chained and multiplexed files it
cannot time. `readLocalAudioInfo` picks the reader by extension. A folder of audio files reads as
one book, cover included, leaving out files in formats the device cannot play.

### `backup`

ADR-0008's gzipped protobuf (generated Dart committed), the codec that refuses corrupt, truncated
and future-version files, and the restore planner, which works listened state out from positions
when restoring a format-version-1 backup written before that state was recorded. `data` reads and
restores the library for it over Drift and signals every change to the tables a backup carries.

Automatic backups: file names that sort by time and are recognisably its own; retention (the newest
three, and the newest of each of the past seven local days); `BackupService`, which writes to the
chosen folder, applies retention and lists a folder's backups from their headers alone; and
`BackupScheduler`, which backs up a few minutes after changes settle, never more than fifteen
minutes after the first, and when the app hides or closes — one at a time, and only when something
changed.

### `test_support`

A fake clock that fires timers, fake folders, an in-memory settings store, and a fake
`ContentSource`. This is how the library writes, the media resolver and every Browse screen are
tested without a site or an engine.

### `platform_adapters` (Flutter)

- The `just_audio` engine adapter.
- `AudioFocus` — the spoken-audio session and its interruption events, through `audio_session`.
- `AudioServiceBridge` — lock screen, notification and Android's background playback service,
  through `audio_service`.
- `SmtcBridge` — Windows' media keys and volume flyout, through `smtc_windows`.
- `SystemMediaControls`, which starts whichever of the two the device needs.
- `StorageLocations`, §5.1's single adapter for storage paths: covers, the stream cache, the folder
  installed extensions are kept in, and the folder an extension can be copied into.
- `SharedPreferencesSettingsStore`.
- `DeviceFolders`, which chooses and keeps folders as directory paths on desktop and as Storage
  Access Framework trees on Android (through `saf_util` and `saf_stream`), and says it cannot yet on
  iOS, where no plugin keeps a folder's security-scoped bookmark.
- `FileDropTarget`, which takes files and folders dropped onto the window on desktop (through
  `desktop_drop`) and is only its child elsewhere.
- `StreamAudioCache` and `CachedAudioSource` — see [streaming](#streaming).
- `QuickJsScriptEngine`, the one place that knows which JavaScript engine the app runs, over
  ADR-0001's vendored fork.
- `EngineFormats`, which says which audio formats the engine plays on this device: all of them
  through ExoPlayer and mpv, and no Ogg through AVFoundation on iOS and macOS.

### `design_system` (Flutter)

`BookCover`, which shows a cover decoded at the size it is shown, or a placeholder — from a file for
a book in the library, and from a URL, with the headers a site needs, for one being browsed.

### `downloads`

Phase 3's queue, and only the queue: the half ADR-0007 keeps on our side of the transport line,
which is the half that can be tested without a device.

- §5.3's **state machine**, as a sealed event set and one `advance` function. Every legal move is
  named and anything else is refused. It is total — an event that does not apply returns null rather
  than throwing, because the transport reports progress and completion whenever it gets round to it,
  possibly after the listener has cancelled. Two deliberate departures from the diagram: pausing
  works from `waiting` and `queued`, not only `downloading`, and resuming returns to `queued` so the
  scheduler decides afresh rather than a task with a stale URL walking back in.
- §5.5's **backoff**: exponential from five seconds, jittered by up to half, never immediate,
  `Retry-After` honoured as a floor up to an hour, five attempts before a retryable failure becomes
  permanent.
- §5.2's **scheduler policy**, as a pure function from the startable tasks, the limits and the state
  of the device to a decision per task. The global cap, the per-source cap, the network policy and
  the free-space floor, with every held task carrying the reason it is waiting.
- The **driver**: one `pump` lets retries that are due rejoin the queue, asks the store what could
  start, asks the policy what may start, and acts. Transport reports are applied through the state
  machine, so a completion for a task just cancelled does nothing instead of crashing. It owns no
  timer — when to pump is the app's decision — and resolution is just in time, reusing a stored
  address unless it has expired or was the one the site refused.
- The **transport interface** ADR-0007 draws the line at: start, pause, cancel, and a stream of
  reports carrying our task ids. Nothing above it is platform-bound.
- §5.2's **post-processor**: a pure check on the first sixty-four bytes — a size floor, a content
  type that condemns a file, the signatures audiobooks come in, and a test for the web page the
  design warns about — and the keeper that names a file after its book, moves it into place with an
  atomic rename, and hands back a path relative to the downloads folder.

A grid test sweeps every event against every state and compares the whole set of legal moves with
§5.3, so a transition added because some later feature found it convenient fails the build. A
download goes from queued to completed in a test, against a fake store and a fake transport.

The queue also has its **store** — `DownloadStore` in `domain`, `DriftDownloadStore` in `data`, the
same division `PlaybackStore` already has.

The **transport** itself is in `platform_adapters`, over `background_downloader`: the thin side of
ADR-0007's line, which retries nothing and applies no network policy of its own, because both belong
to the queue. It is the one layer here that cannot be unit tested, so what stands behind it is that
CI builds it on Android, Windows and iOS.

**What is missing**: the reconciler (§5.2), wiring any of it into the app, and every screen. **No
byte has been downloaded**, on any platform — nothing calls the driver yet.

### `sync`

Empty scaffolding.

## The app

A first vertical slice.

**Adding books.** An M4B, MP3, FLAC, Ogg Vorbis or Ogg Opus file, or on desktop a folder of audio
files, through a file dialog or by dropping onto the window; or a book from the LibriVox source. The
library watches the database, with Continue Listening above it.

**A book's details.** Chapters and listened state; mark a chapter listened or not from its menu, the
book finished or not, or take it out of the library.

**The player.** Seeking, 30-second skips, chapter navigation, a chapter list (a sheet on a phone, a
side panel on a wide window), speed, a sleep timer and keyboard shortcuts.

**Routing.** go_router's typed routes (ADR-0005), declared in `app/lib/src/routes.dart`: home at
`/`, a book at `/book/<id>`, the player at `/player`, Settings at `/settings`, restore at
`/settings/restore`, Browse at `/browse` with a source at `/browse/source` and one of its books at
`/browse/source/book`, all above the home, and first-start setup at `/setup`. §2.6's shell is two
tabs so far — Library and Browse, a bottom bar on a narrow window and a rail on a wide one — with
Settings still in the library's app bar, because a More tab would hold nothing else yet.

**Backups.** Scheduled once a backup folder is chosen. An empty library offers a setup screen
through a redirect: choose a folder, restore from a backup in one, or skip. Settings holds the
Backup section (the folder, the last backup, backing up now, restoring, and a folder that can no
longer be reached), and a reminder stays on the home until a folder is chosen. None of this is
offered on iOS yet.

**Covers.** A local book's cover is kept when the book is added, looked for in the background for
books added before and for books a restore brings back, and shown in the library, on Continue
Listening, on a book's details and in the player. Custom covers are still to come.

**Formats.** A book in a format this device cannot play, as Ogg is on iOS, is refused as it is
added, with the format named; a folder's files in such a format are left out of its book and named,
as damaged files are.

**Driving it without a dialog.** Passing a file or folder path as the first command-line argument
imports and opens it at start. On iOS and Android the file dialog hands over only a temporary copy,
so a picked book is moved into the app's `Import` folder, which on iOS is visible in the Files app.
Books copied into that folder are added at start and whenever the app returns to the foreground.

## Extensions

The LibriVox extension ships **inside the app**, as an asset in §3.3's package format:
`app/assets/extensions/librivox/manifest.json` and one ES2020 `main.js` written against
SourceAPI 1.0. Its `main.js` is refused if its SHA-256 does not match the manifest.

**Installing one from a folder** is the door ADR-0017 opened. A folder holding a `manifest.json` and a
`main.js` is read with the same reader the asset is, both files are copied into the app's own storage
under `<id>/<versionCode>`, and the install is recorded, so it is still there after a restart. Three
ways in, all ending in the same install:

- the platform's folder picker — a path on desktop, a Storage Access Framework tree on Android;
- `--extension <folder>` on the command line, for an edit-and-reload loop on a desktop;
- a folder copied into the app's own `Extensions` folder, offered where the listener can see that
  folder, which is iOS.

A folder install does **not** check the manifest's hashes and is recorded as `untrusted`, shown as
**Unverified**: in a folder an author is working in, a stale hash means the code was edited, not that
anything is wrong. **Reload** re-reads the folder it came from and stops the extension's runtime, so
the next use runs the new code. **Remove** takes the code and the row and nothing else — the books,
their progress, the `source` rows and what the extension had stored all stay, and the source becomes
§3.9's stub, which says it is not installed when anything opens it.

The **Extensions screen**, reached from Browse, lists what is installed with its version, where it came
from, whether it was verified and how many failures it has produced, and offers installing, reloading
and removing. The **console** screen (§3.11) shows what extensions logged and what the app logged about
them, for every extension or for one, newest first, with one tap to copy it all for a bug report.

A source registry reads the manifests at start, writes a `source` row for each (§4.3) and runs no
extension code. A source's runtime starts on first use, in a worker isolate of its own, with `http`
on the app's one `NetworkService`, `storage` in the database and `log` in the extension console. An
install or a removal takes effect without a restart: Browse follows the source list as it changes.

**Browse** lists the sources. A source shows what it calls popular and what a search finds, as a
grid of covers that pages as the listener scrolls, with the source's own filters. A book at the
source shows its description, credits and chapters, and Add to library, after which it is a book
like any other. A source book's cover is fetched through the extension's `getImageRequest` when it
declares one, held to its declared domains, and kept in the covers folder as a local book's is.

**Failures.** Every `SourceException` kind, an extension that will not load, and one whose manifest
will not read each get a sentence of the app's own and, where it can help, Try again or Open in
browser; the extension's own words go underneath, never as the explanation. The player shows a
streamed book's failures the same way, named after its source, with Try again bound to playing
again, which re-resolves the URL. A local file that has gone is not a source's doing and is still
shown as it is.

**Local files** is listed in Browse and has a `source` row, but has no `ContentSource` yet: the
Local source proper (§3.10) is a later step, so tapping it goes to the library.

### Streaming

A streamed book plays through `SourceMediaResolver`, so progress, smart rewind, listened state, the
sleep timer, the media keys and Continue Listening all work on it as on a local book, and a book can
be opened and scrubbed before any chapter has been resolved.

Opening one resolves **only the chapter about to be played** and leaves the rest to be resolved when
the engine first needs their bytes, finishing the job in the background once playback has started.
A book of a hundred chapters no longer costs a hundred calls to its source before a note is heard.

The bytes a stream fetches are kept in the platform's cache folder, bounded at 512 MB and pruned
least-recently-used, so a skip, a chapter played again and the same book opened tomorrow are reads
from the device. This is **not** §5.2's downloads: nobody asks for it, nothing in the database knows
about it, and the OS may empty it.

In a debug build the console reports what each step of opening and playing a book cost
(`kikuyomi timing open.resolve 1871 ms` and so on). Turn it off with
`--dart-define=kikuyomi.timings=false`.

Measured against the live site on a ~30 KB/s connection: opening a nine-chapter LibriVox book went
from 9.2 s of resolve calls to a single 1.7 s fetch; reading a cached chunk back is ~26 ms against
seconds over the network. The connection, not the Archive, is the ceiling for a first listen — a
64 kbps MP3 needs 8 KB/s, so there is 3–4× headroom.

## What has been run for real

The extension system was first driven on a device on 24 September 2026, and the section below says
what that established. It is worth recording what those few hours cost, because it is the argument
for doing it sooner next time: three defects surfaced that a green test run and a clean build had
both missed — a `TypeError` reaching the app with its stack thrown away, a failed open leaving the
player unable to start any book including local ones, and this guide's own advice to cache something
the host frees at the end of a call. All three are fixed. None was visible from inside the tests.

- **Windows**: the library, the player, backups, adding local books, and building and launching the
  app. Still untried here: the LibriVox path, and FLAC/Ogg books with real files. Whether an
  extension has been installed from a folder on Windows is not confirmed; assume it has not.
- **iOS**: a good deal, on an iPhone, through the CI-built canary IPA run under LiveContainer.
  Installing an extension from the Files-visible `Extensions` folder, the Extensions screen,
  removing one, installing it again, the extension console, browsing a source, and a book's details
  and chapters. And **LibriVox: browse, resolve and play** — the first time the streaming path has
  run anywhere outside a test.
- **Android**: still nothing, on an emulator or a device, outside the probe in CI. It now carries the
  most untested new code of any platform: the Storage Access Framework is the install door there,
  and no real folder has been through it.
- **LibriVox**: browsing, resolving and streaming work on iOS. Untried on Windows and Android.

### The probe

The extension cannot run under `flutter test`, which does not build the engine's native library, so
it runs on the real engine in the Phase 0 probe, `spikes/quickjs_binding/qjs_probe`. That spike has
outlived its throwaway purpose and is kept.

Thirty-four probes, all passing on Windows and on API 26 and API 35 emulators in CI
(`.github/workflows/android-emulator.yml`, which runs on pushes touching the fork, the spike, the
engine, the interface, the contract or the bundled extensions):

- **13–19** drive `ScriptEngine` itself.
- **20–22** run the extension protocol with the real prelude.
- **23–34** run the LibriVox extension the app ships, against answers recorded into the probe's
  assets and never against the live site. The probe's `main.js` is a copy of the app's, which an app
  test holds equal to it. Probe 31 runs it in a worker isolate, which is the only place a QuickJS
  runtime is started where the app starts one.

ADR-0001's fork is vendored in `third_party/flutter_qjs`, with every change listed in
`README.kikuyomi.md`. Android forced a wall-clock interrupt deadline, since there `clock()` counted
the whole process's CPU time, and an `InternalError: out of memory` where QuickJS throws `null`. The
host arms a deadline for one call and no entry from Dart restarts it, so `while (true) log('x')` is
stopped, and a running script can be cancelled from another isolate even when it never yields.

What is left is an **arm64 device**: the probe has run on x86_64 emulators and on Windows only.

### CI

`.github/workflows/ci.yml` builds an Android APK, a Windows build and an unsigned iOS IPA on every
push, and runs the tests in every package that has them.

## Step A, done

All six parts, recorded in ADR-0017: a package read from a real folder as strictly as the asset is;
schema version 2's `extension` and `extension_preference` tables, with a migration and a migration
test; an Extensions screen with what is installed, remove, reload and each extension's failures; the
console surfaced on a screen of its own; installing from a folder through the picker, the
`--extension` flag and, on iOS, the app's own visible folder; and §3.9's answer for a removed
extension — the books stay and the source becomes a stub.

The two questions Step A left open were decided in ADR-0017. A folder install does not check the
manifest's SHA-256 and is marked unverified, because in an author's folder a stale hash means the code
was edited. And `sources.extension_id` stays a plain id rather than becoming a foreign key, because a
source has to outlive the extension it came from.

Most of it has since been driven on an iPhone: installing from a folder, the Extensions screen,
removing and installing again, and the console. What has not is Android — where the Storage Access
Framework is the door — and the folder picker on desktop. See
[what has been run for real](#what-has-been-run-for-real).

## What is next

### Phase 3 — offline, in progress

The queue exists and nothing fetches anything yet. What is built is listed under
[`downloads`](#downloads) and in schema version 3's `download_task` table; what is left, in order:

1. **Wiring it into the app.** The composition root builds the store, the transport, the
   post-processor and the driver, and something decides when to pump: after enqueueing, when the
   network changes, when a task finishes. This is the next thing, and the first point at which a
   byte can actually move.
2. **Probing a kept file** for its real duration, format and embedded markers, which §5.2 puts in
   the post-processor and which is the one part of it not built. `sources_builtin` already has the
   readers; nothing has been wired to call them after a download. Until it is, §4.5 refines a
   duration the first time the engine plays the file, which is late but not wrong.
3. **The reconciler** (§5.2), matching the transport's live tasks to rows at launch and sweeping
   orphans. This is also where a task orphaned by a layout rewrite is repaired — an estimate is
   usually consumed in place, but a resolution that changes a chapter's shape drops it and takes the
   task with it.
4. **The screens** (§5.6): what is downloading, per-book and per-chapter sizes, delete, and the
   automatic policies.

The exit criterion is the roadmap's: a full book downloaded and finished with no network.

### Step B — the repository door

Installing from a URL, as Mihon does (§3.8, §3.9).

1. An index format: for each extension its id, name, version, apiVersion, declared domains, icon,
   the URL of its `main.js` and that file's SHA-256. A versioned public format, so it gets written
   down as the manifest is.
2. Fetching and parsing it; accepting a plain `github.com/user/repo` URL and working out the raw
   one, as Mihon does.
3. Managing a list of repositories, browsing one, installing, updating, uninstalling.
4. Update checks against the index.

**Trust.** Mihon gets one protection free from Android: the OS refuses an update signed with a
different key than the install. A JavaScript bundle gets nothing free. The proposal is to ship
without signing — the index is fetched over HTTPS and pins each bundle's SHA-256, so a repository is
as trustworthy as whoever runs it — and to leave room in the index format for signatures later. Not
yet decided.

The app ships knowing only the official repository. Per `CLAUDE.md`, neither the app nor the docs
list or recommend any other.

### Loose ends

- The folder **picker** path has never been driven by the running app: installing on iOS goes through
  the app's own `Extensions` folder, not `UserFolders.choose()`, so the desktop path and Android's
  Storage Access Framework tree are still exercised only by tests. Reload is untried too.
- An extension is never verified once it is installed from a folder, so `untrusted` is the normal
  state. When repository installs arrive, `active` will start to mean something (ADR-0017).
- Nothing rolls back to an earlier installed version, although the versioned directory keeps one.
- A backup does not carry which extensions a library wants; it waits for the repository door and a
  backup format version of its own (`backupLeavesOut` names the tables and says why).
- Browse grid covers bypass the app's HTTP client.
- Android `minSdk` is 24; ADR-0012 says 26.
- Android has never been run for real.
- Local files is not a real `ContentSource` yet (§3.10).
- A stale cover file is not deleted when a cover URL changes.
- A Timeline can go stale when a resolution rewrites a chapter's layout.
- Prefetching the next chapter's bytes while the current one plays would make chapter skips instant
  on a streamed book. Not built.
- FLAC and Ogg books have not been tried with real files in the running app.
