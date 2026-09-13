# Kikuyomi: project guide for Claude

## What this is
Kikuyomi is an open-source (Apache-2.0), cross-platform audiobook player whose content comes from installable JavaScript source extensions, inspired by Mihon and Aniyomi. Built with Flutter. Android and Windows are the primary targets; iOS is planned but there is no Mac yet, so iOS is only built as an unsigned canary IPA in CI.

The approved design is `docs/architecture.md` (v0.3). Individual decisions are recorded in `docs/adr/`. Read the relevant sections before proposing structural changes.

## Current status
Phase 0: environment setup, CI skeleton, and spikes. Spikes live in `spikes/` and are throwaway; their purpose is to answer the questions listed in the roadmap and produce ADRs. Production code in `app/` and `packages/` starts in Phase 1.

## Repository layout (target)
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
- `flutter run -d windows` (from `app/`; the repo root is the workspace root, not an app)
- `flutter run -d <emulator-id>` (see `flutter devices`)
- `dart test` (inside a pure-Dart package)
- `flutter analyze`
- `dart format app packages`. Not `dart format .` at the repo root: the local `flutter/` SDK checkout lives there and `.` walks into it.
