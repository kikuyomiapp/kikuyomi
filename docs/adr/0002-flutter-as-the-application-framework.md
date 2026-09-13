# ADR-0002: Flutter as the application framework

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §2.5, decision 1

## Context

The project began as a native SwiftUI design. That design was abandoned for a reason that has
nothing to do with taste: **SwiftUI requires Xcode, Xcode requires macOS, and the development
machine is a Windows PC.** A framework that cannot be built on the only available machine is not a
framework, whatever its merits.

The requirement is one codebase serving Android and Windows now and iOS later, with a
native-quality audio player. Audio is the load-bearing word. This is not a CRUD app with a media
tab; background playback, lock-screen controls, audio focus, and media keys are the product.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Flutter** | One UI across all five targets; first-class Windows support; mature audio, background and download packages; hot reload; Mangayomi is a working precedent for this exact category of app | Draws its own widgets, so "native design" means Material 3 done well rather than literal platform controls | **Chosen** |
| Kotlin Multiplatform + Compose Multiplatform | Kotlin is close to Java, and Mihon's code — the closest reference implementation — is Kotlin | Player, background playback, media controls and download transport would each be written per platform; JVM desktop audio options are weak | Rejected |
| Native per platform | Best possible fidelity on each | Three codebases, and the iOS one cannot be built at all today | Rejected |
| SwiftUI (the v0.2 design) | — | Cannot be built on Windows | Superseded |

## Decision

Flutter, with Dart, for the entire application. Android and Windows are primary targets; iOS is a
planned target compiled in CI from Phase 0 onward so it never silently stops building.

## Consequences

The trade-off accepted is **visual fidelity for reach**. Flutter paints its own widgets, so the
app will look like a well-executed Material 3 application with platform-appropriate adaptations,
not like a set of native controls. For a media player with a strong visual identity this is a
smaller loss than it would be for a utility.

The trade-off gained is that the audio problem is solved once. `just_audio`, `audio_service` and
`background_downloader` cover all three targets, and the per-platform work reduces to
configuration inside `platform_adapters` rather than three implementations.

What must stay true: **every dependency must support Android, Windows and iOS**, or sit behind an
adapter with a known alternative on the missing platform. The moment that stops holding, the
single-codebase argument weakens. This is why the rule is in `CLAUDE.md` and why new dependencies
are discussed before they are added.

The escape hatch is weak, and that is worth being honest about. Framework choice is the one
decision here that cannot be reversed behind an interface. Reversing it means rewriting the
application layer. The mitigation is that the domain, data and extension logic all live in
pure-Dart packages with no Flutter dependency, so the *logic* would survive a framework change
even though the UI would not.
