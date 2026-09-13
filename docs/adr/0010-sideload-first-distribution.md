# ADR-0010: Sideload-first distribution

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §7.2, decision 11

## Context

An app whose content comes from user-installed extensions has a difficult relationship with app
stores. Google Play and the App Store both hold a developer responsible for everything a plug-in
does, and this app cannot make promises about extensions it does not write. Mihon, the closest
precedent, is not on Play for exactly this reason, and Tachiyomi's history is the cautionary tale.

Two external deadlines press on this. **Google's Android developer verification programme** changes
sideloading from late 2026 onward, with a global rollout following, so distributing an APK will
require a registered, verified developer identity rather than being anonymous. And on iOS,
sideloading is only viable through AltStore or SideStore, with free Apple IDs limited to seven-day
signing and three active apps.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Sideload-first: GitHub Releases plus in-app update checks** | No store review of third-party extensions; full control over release cadence; works identically on Android and Windows | Users must trust an unsigned binary; SmartScreen warnings on Windows; no store discovery | **Chosen** |
| Google Play and App Store | Discovery; automatic updates; user trust | Store policy makes the developer answerable for every extension; the core feature is the problem | Rejected |
| F-Droid only | Aligned with open-source distribution | Reproducible-build requirements are demanding; Windows and iOS unaddressed | Later, possibly |

## Decision

Sideload-first on every platform. Android APKs and Windows builds ship through GitHub Releases
with an in-app update checker; iOS ships later through an AltStore-format source feed that works
in both AltStore and SideStore. **Register as a verified Android developer** ahead of the 2027
global rollout.

## Consequences

The verified-developer registration is the item with a real deadline attached, and it is the one
most likely to be forgotten because it has nothing to do with code. It belongs in Phase 6 and it
should not slip, because missing it means the APK stops installing for ordinary users.

On Windows, unsigned executables trigger SmartScreen until they accumulate reputation, which is a
poor first impression for a project whose whole trust story is "you can read the source". Free
code signing through programmes such as the SignPath Foundation is worth pursuing before 1.0.

The in-app update checker is not a convenience; it is the **only** update mechanism. Without a
store there is nothing else to tell a user their build is old, and an app that silently rots is
worse than one that nags.

**Enterprise-certificate signing services must be avoided** on iOS. Their shared certificates get
revoked in waves, taking every app signed with them offline at once.

**The escape hatch is a `DistributionPolicy` seam.** A store edition remains possible later: it
would need to satisfy the plug-in guidelines, and the `ScriptEngine` interface already allows
switching to JavaScriptCore on Apple platforms if review ever demands it. Nothing in this decision
forecloses that, which is why the policy is a seam rather than an assumption spread through the
code.
