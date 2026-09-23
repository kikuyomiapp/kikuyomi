# Kikuyomi: project guide for Claude

## What this is
Kikuyomi is an open-source (Apache-2.0), cross-platform audiobook player whose content comes from installable JavaScript source extensions, inspired by Mihon and Aniyomi. Built with Flutter. Android and Windows are the primary targets; iOS is planned but there is no Mac yet, so iOS is only built as an unsigned canary IPA in CI.

The approved design is `docs/architecture.md` (v0.3). Individual decisions are recorded in `docs/adr/`. Read the relevant sections before proposing structural changes.

## Current status
Phase 2, extensions. The workspace and its fourteen packages exist and are unit tested, and the app
is a working vertical slice: add local books or LibriVox books to a library, see a book's chapters
and listened state, and play it with seeking, chapter navigation, speed, a sleep timer, system media
controls and automatic backups. The LibriVox extension runs for real, in a worker isolate of its
own, over the QuickJS fork vendored in `third_party/`. There is still no way to install an
extension; that is the work in progress.

**`docs/status.md` has the detail** — what each package holds, what the app does, what has and has
not been run on a real device, and what the next two steps are. Read it before proposing work, and
update it when the answer changes. This section stays short on purpose: it is re-read on every
prompt, and an inventory that grows every week belongs in a document, not in a guide.

Two things to know before trusting a green test run. **Android has never been run for real**, on an
emulator or a device, outside the probe in CI. And **nothing to do with LibriVox has been driven by
the running app on any platform** — browsing, searching, adding a book and streaming one have been
exercised only by tests and by the Phase 0 probe.

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
docs/                 architecture.md, status.md (what exists now), adr/
spikes/               Phase 0 experiments
third_party/          vendored forks, outside the workspace (flutter_qjs, ADR-0001)
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
