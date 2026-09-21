# Kikuyomi: project guide for Claude

## What this is
Kikuyomi is an open-source (Apache-2.0), cross-platform audiobook player whose content comes from installable JavaScript source extensions, inspired by Mihon and Aniyomi. Built with Flutter. Android and Windows are the primary targets; iOS is planned but there is no Mac yet, so iOS is only built as an unsigned canary IPA in CI.

The approved design is `docs/architecture.md` (v0.3). Individual decisions are recorded in `docs/adr/`. Read the relevant sections before proposing structural changes.

## Current status
Phase 0: environment setup, CI skeleton, and spikes. Spikes live in `spikes/` and are throwaway; their purpose is to answer the questions listed in the roadmap and produce ADRs. `spikes/README.md` carries the current status of each and what is blocking.

The workspace and the fourteen packages under `packages/` exist. Phase 1 has begun, ahead of Phase 0's Android items. In the pure-Dart core, `domain` holds the Timeline, the `Clock`, `PlaybackStore` and `MediaResolver` interfaces, the `ListeningSession` entity, the types backups share with `data`: the library snapshot, the restore plan and the interfaces that read and restore the library, §4.3's typed settings store (`SettingsStore`, with every key in `AppSettings`), and `UserFolders`, the interface to folders the user chooses outside the app's storage; `playback` holds the `PlaybackCoordinator` and the engine contract it drives, with the progress-write rules, smart rewind, the sleep timer, listening-session recording, §6.5's interruption rules, refining a file's estimated duration once the engine reports the real one (§4.5), and the sync that keeps the system's media controls in step; `data` holds Drift schema version 1, the §4.4 chapter-sync and book-details merges, loading a book's Timeline for playback, the Drift-backed `PlaybackStore`, importing local books of one file or of several, the import folder that keeps picked files, the watched read models behind Continue Listening and a book's details, taking a book out of the library, and keeping local books' covers in the covers folder, including finding the covers of books added before covers were kept; `sources_builtin` holds the M4B and MP3 readers, which also read embedded cover art, reads a folder of audio files as one book, cover image included, and reads a local book's cover from its files; and `backup` holds the backup format (ADR-0008's gzipped protobuf, with the generated Dart code committed), the codec that refuses corrupt, truncated and future-version files, and the restore planner, while `data` reads and restores the library for it over Drift and signals every change to the tables a backup carries. On top of those, `backup` holds automatic backups: file names that sort by time and are recognisably its own, retention (the newest three, and the newest of each of the past seven local days), `BackupService`, which writes a backup to the chosen folder, applies retention and lists a folder's backups from their headers alone, and `BackupScheduler`, which backs up a few minutes after changes settle, never more than fifteen minutes after the first, and when the app hides or closes, one at a time and only when something changed. `test_support` holds a fake clock that fires timers, fake folders and an in-memory settings store. All of it is unit tested. `platform_adapters` holds the `just_audio` engine adapter, `AudioFocus` (the spoken-audio session and its interruption events, through `audio_session`), `AudioServiceBridge` (the lock screen, the notification and Android's background playback service, through `audio_service`), `SmtcBridge` (Windows' media keys and volume flyout, through `smtc_windows`), `SystemMediaControls`, which starts whichever of the two the device needs, `StorageLocations`, §5.1's single adapter for storage paths, covers folder included, `SharedPreferencesSettingsStore`, `DeviceFolders`, which chooses and keeps folders as directory paths on desktop and as Storage Access Framework trees on Android (through `saf_util` and `saf_stream`) and says it cannot yet on iOS, where no plugin keeps a folder's security-scoped bookmark, and `FileDropTarget`, which takes files and folders dropped onto the window on desktop (through `desktop_drop`) and is only its child elsewhere. `design_system` holds `BookCover`, which shows a cover decoded at the size it is shown, or a placeholder.

The app is a first vertical slice: add books (an M4B or MP3 file, or on desktop a folder of audio files) through a file dialog or, on desktop, by dropping them onto the window, to a library that watches the database, with Continue Listening above it; open a book's details to see its chapters and listened state or take it out of the library; and play it on a player screen with seeking, 30-second skips, chapter navigation, a chapter list (a sheet on a phone, a side panel on a wide window), speed, a sleep timer and keyboard shortcuts. Screens are reached through go_router's typed routes (ADR-0005), declared in `app/lib/src/routes.dart`: the home at `/`, a book's details at `/book/<id>`, the player at `/player`, Settings at `/settings` and restoring from a backup at `/settings/restore`, all above the home, and first-start setup at `/setup`. There is no tabbed shell yet. Backups are scheduled once a backup folder is chosen. When the app starts with an empty library it offers a setup screen, through a go_router redirect, to choose a folder, restore from a backup in one, or skip; Settings, from the home's app bar, holds the Backup section (the folder, the last backup, backing up now, restoring, and a folder that can no longer be reached); and a reminder stays on the home until a folder is chosen. None of this is offered on iOS yet. A local book's cover is kept when the book is added, looked for in the background for books added before and for books a restore brings back, and shown in the library, on Continue Listening, on a book's details and in the player; covers from online sources and custom covers are still to come. So far it has been exercised on Windows; the CI-built IPA also launches on the iPhone. Passing a file or folder path as the first command-line argument imports and opens it at start, which is how the app is driven without a file dialog. On iOS and Android the file dialog hands over only a temporary copy, so a picked book is moved into the app's `Import` folder, which on iOS is visible in the Files app. Books copied into that folder are added at start and whenever the app returns to the foreground. The other packages are still empty scaffolding. CI builds an Android APK, a Windows build and an unsigned iOS IPA on every push, and runs `dart test` in every package that has tests.

All fifteen decisions in §9 of the architecture document have ADRs in `docs/adr/`. Fourteen are Accepted; ADR-0001, the QuickJS binding, is still Proposed pending an Android run.

## Repository layout
```
app/                  Flutter app: composition root, routing, feature folders, adaptive shell
packages/
  source_api/         extension contract (pure Dart, versioned: treat as a public API)
  domain/             entities, use cases, interfaces, Timeline (pure Dart)
  data/               Drift schema, migrations, repositories
  networking/  source_runtime/  sources_builtin/  extension_manager/
  downloads/  playback/  backup/  sync/
  platform_adapters/  design_system/  test_support/
docs/                 architecture.md, adr/
spikes/               Phase 0 experiments
```
Folder names are short; `pubspec` names use a `kikuyomi_` prefix (e.g. `kikuyomi_domain`). The repo is a Dart pub workspace.

## Architecture rules
- Pure-Dart packages never import Flutter or platform plugins. Only `app`, `platform_adapters`, and `design_system` depend on Flutter.
- No `Platform.isX` checks inside features. Platform differences go behind an interface in `platform_adapters`.
- Every new dependency must support Android, Windows, and iOS, or sit behind an adapter with a known alternative. Ask before adding one, and state its platform support.
- The database is the single source of truth; UI watches Drift streams instead of holding copies of data.
- Extension output is untrusted: decode it into strict types and validate it at the boundary.
- Playback progress is stored chapter-relative; global position is derived from the Timeline.
- Engine queue items are physical files, not chapters.
- Never hardcode the application ID or bundle ID; read them at runtime.
- Changes to `source_api` are changes to a versioned public contract. Ask first; minor versions are additive only.

## Quality
- Logic in pure-Dart packages ships with `dart test` unit tests.
- Every schema change comes with a Drift migration and a migration test.
- Code must pass `dart format` and `flutter analyze` with no warnings.
- Judge whether CI will pass from a fresh clone of the committed tree, never from the working tree. Packages resolved by hand on the development machine, such as the spikes, make local runs pass where a clean checkout fails; that once hid a red build across a dozen commits.
- Use sealed classes and pattern matching for state; prefer immutable models.

## Legal boundaries (non-negotiable)
- Never create extensions, fixtures, or sample data for unauthorized or copyrighted sources. The official repository contains only public-domain or openly licensed catalogs (e.g. LibriVox, Internet Archive public domain).
- Never write code that removes or bypasses DRM.
- The app and docs never list or recommend third-party repositories.

## Working with me
- I come from Java. When a Dart or Flutter idiom differs meaningfully from Java, point it out briefly.
- When showing code for me to review or copy, give complete files with their paths, not fragments.
- I develop on Windows with the Android emulator and Windows desktop as run targets. I can test iOS only by sideloading CI-built IPAs onto my iPhone.

## Common commands
- `flutter pub get` (at repo root, resolves the whole workspace). Not `dart pub get`: the workspace has a Flutter member, whose `sdk: flutter` dependencies plain pub cannot resolve.
- `flutter run -d windows` (from `app/`; the repo root is the workspace root, not an app). Needs rustup installed: `smtc_windows` builds a Rust crate as part of the Windows build. CI's `windows-latest` runner already has it.
- `flutter run -d <emulator-id>` (see `flutter devices`)
- `dart test` (inside a pure-Dart package)
- `dart run build_runner build` (inside `app/` for the typed routes, inside `packages/data` for the Drift schema). Generated files are committed, because CI does not run code generation; regenerate after changing routes or tables.
- `flutter analyze app packages`. Not bare `flutter analyze`: spike packages are not workspace members, so on a fresh checkout their imports are unresolved and analysis fails, while a machine where the spikes were resolved by hand passes. CI runs the scoped form.
- `dart format app packages`. Not `dart format .` at the repo root: the local `flutter/` SDK checkout lives there and `.` walks into it.
