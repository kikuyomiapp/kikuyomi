# ADR-0017: Installing extensions from a folder

- **Status:** Accepted
- **Date:** 2026-09-23
- **Relates to:** `docs/architecture.md` §3.3, §3.8, §3.9, §3.11 and §4.3; ADR-0016

## Context

Phase 2's contract, runtime and bundled extension all exist, and the app browses, adds and streams a
LibriVox book. What it cannot do is take an extension it did not ship with. Nobody outside this
repository can write one, and nobody inside it can test a change to one without rebuilding the app,
so the door has to open before anything else in Phase 2 is worth building.

The design's own door is a repository (§3.8, §3.9): an `index.json` over HTTPS, an Ed25519 signing
key pinned on first use, packages verified at install. That is the right door for a listener, and it
is the wrong first door for an author. An author's extension does not exist at a URL yet, and the
loop they run fifty times a day is *edit `main.js`, see what the app does*. So the first door is a
folder, and everything a repository needs later is built here anyway: reading a package, verifying
it, unpacking it into a versioned directory, recording it, and registering its sources.

Three constraints shaped the rest.

**A folder is not the same thing on every platform.** On Windows it is a path. On Android a folder the
listener picks is a Storage Access Framework tree, which plain file access cannot open, and whose
permission has to be persisted. On iOS it is neither: keeping access to a folder outside the app takes
a security-scoped bookmark, and no maintained plugin creates one, which is why
`DeviceFolders.forThisDevice()` reports that iOS cannot choose a folder at all (§5.1, Appendix A).

**A manifest's `files` hashes do not mean what they mean in a package.** §3.3 puts the SHA-256 of
every file in the manifest, and §3.8 verifies them at install and re-checks them at load. That proves
a package was assembled as one piece. In a folder an author is working in, it proves only which
version of `main.js` they last took a hash of — which is never the one on disk, because taking the
hash is the last step of a build and editing is what happens after.

**Removing an extension must not remove a library.** §3.9 is explicit: "Uninstalling removes the code
but not the user's data: library books from that source keep their metadata, progress, and downloads,
and point to a stub source until the extension returns or the books are migrated." Schema version 1
left a note in `tables.dart` saying `source.extension_id` would become a foreign key once the
`extension` table arrived. It cannot: a foreign key forces the uninstall to fail, or the link to be
lost, or the books to be deleted with it.

## Options considered

| Question | Options | Verdict |
|---|---|---|
| The first way in | A repository, a folder, or a `.kyx` file through the file picker | **A folder.** A repository needs an index, signing keys and a trust store before an author can test one line; a file picker hands over a copy of one file, and a package is two. A folder is what an author already has, and it works through the picker every platform but iOS already provides |
| Whether a folder install verifies the manifest's hashes | Always, never, or with an "install anyway" prompt | **Never, and say so.** The check would fail on almost every install an author makes, and a prompt on every save is a prompt nobody reads. The extension is recorded as `untrusted` (§4.3's own status value) and the Extensions screen labels it **Unverified** |
| Where an installed extension's code lives | Copied into app storage, or read from the origin folder at every start | **Copied**, into `<app data>/installed_extensions/<id>/<versionCode>/`, which is §3.9's versioned directory. A folder the listener picked can be moved, deleted or revoked, and on Android a tree permission read on the launch path is both slow and losable. The copy also means iOS needs nothing it cannot do |
| How an author picks up an edit | Re-install from the picker, a Reload action, or watch the folder | **A Reload action.** The origin handle is recorded, so one tap re-reads the folder and replaces the copy. Watching a folder means a file watcher per install on three platforms, for a convenience one tap already buys |
| iOS, which can keep no picked folder | Wait for security-scoped bookmarks, or install from a folder inside the app | **A folder inside the app**: `<Documents>/Extensions`, which the Files app shows because `UIFileSharingEnabled` is already set for books (§5.1). The listener copies an extension folder in; the Extensions screen lists what is there and installs it. The same code serves a `--extension` path on a desktop |
| `source.extension_id` as a foreign key | Restrict, set null, cascade, or no foreign key | **No foreign key.** Restrict makes uninstalling impossible while any book remains, set null loses which extension the source wants back, and cascade deletes the listener's books. The source keeps the id as plain text, and a source with no installed extension is §3.9's stub |
| Whether a backup carries what is installed | Yes, or leave it out for now | **Leave it out**, named in `backupLeavesOut` with the reason. A backup carries no extension code and a folder path means nothing on another device. Naming the extensions a restored library wants is worth doing, and needs somewhere to install them from, so it goes with the repository door and a backup format version of its own |

## Decision

An extension is installed from a folder holding a `manifest.json` and a `main.js`. The manifest is
read as strictly as any third-party data (`ExtensionManifest`), the `files` hashes are **not** checked,
both files are copied verbatim into `<app data>/installed_extensions/<id>/<versionCode>/`, and the
install is recorded in schema version 2's `extension` table with `status = untrusted` and the origin
folder's handle. The app refuses, before writing anything, an extension whose contract version or
`minAppVersion` this app cannot run, with the same sentence a refusal at start uses.

The folder is reached in three ways, all of which end in the same install: the platform's folder
picker (`UserFolders`: a path on desktop, a SAF tree on Android), a `--extension <folder>` flag on the
command line, and a folder copied into the app's own `Extensions` folder, which is offered where that
folder is visible to the listener, as it is on iOS.

Reload re-reads the recorded origin and replaces the copy, stopping the extension's runtime so the
next use runs the new code. Remove deletes the code and the `extension` row, and nothing else: the
`source` rows, the books, their progress, their bookmarks and the extension's stored preferences all
stay, and the source becomes a stub that says "not installed" when anything opens it.

Schema version 2 also adds `extension_preference`, so an extension's `storage` survives a restart
instead of living in memory.

## Consequences

**Easy.** Writing an extension: build, install the folder once, then edit and reload. Testing the
whole install path on Windows, where development happens. Adding the repository door later — it reads
a package, verifies hashes, writes it to the same versioned directory and records it with
`origin = repository`, all of which exists.

**Hard, or deliberately unsolved.** A folder install is never verified, so `untrusted` is the normal
state rather than a warning sign; when repository installs arrive, `active` will mean something and
this label will have to keep meaning what it says. Nothing enforces one extension's code being what
its author published until signatures exist (§3.8), which is exactly why the app ships knowing only
the official repository. Updates install side by side but nothing rolls back to an earlier version
yet: the versioned directory makes it possible, and no screen offers it.

**What has to stay true.** `source.extension_id` must stay a plain id, or §3.9's stub source stops
working. An install path must stay relative to the installed-extensions folder, because on iOS the
app's container moves when the app is updated.

**The escape hatch.** Installing is `ExtensionInstallFolder` (where the files go) behind
`ExtensionFiles` (where they come from) and `ExtensionLibrary` (what the app does with them). A
different install model — reading a folder at every start, or unpacking a signed `.kyx` — replaces
`ExtensionFiles` and `ExtensionInstallFolder` and leaves the database, the registry and every screen
as they are.
