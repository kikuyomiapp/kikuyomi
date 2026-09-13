# ADR-0005: go_router for navigation

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §2.5 and §2.6, decision 6

## Context

Navigation has to satisfy three requirements that a plain `Navigator` makes awkward.

**Deep links are a product feature, not a nicety.** `kikuyomi://add-repo?url=…` is how a user adds
a source repository, and `kikuyomi://book/…` is how sharing works. On Android that is an intent
filter and on Windows a protocol handler registered by the installer, but both need to resolve a
URL to a screen with arguments.

**The shell is adaptive.** Phones get a bottom navigation bar, wide windows get a navigation rail,
and the four tabs keep independent history. Nested navigators inside a persistent shell is exactly
the case imperative navigation handles worst.

**A player is always potentially present.** A mini-player above the navigation bar on phones and a
persistent player bar on desktop both mean the route stack is not the whole UI.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **go_router** | Declarative; first-class deep linking; `StatefulShellRoute` for per-tab history under a persistent shell; typed routes via generation; maintained by the Flutter team | Its own redirect and refresh semantics to learn | **Chosen** |
| auto_route | Powerful; strong code generation; mature nested routing | Heavier generation step; smaller community than the Flutter-team option | Rejected |
| Plain Navigator 2.0 | No dependency | The API this decision exists to avoid writing by hand | Rejected |
| Plain Navigator 1.0 | Simple | Deep links and nested shell history become manual bookkeeping | Rejected |

## Decision

go_router, with typed routes, a `StatefulShellRoute` for the adaptive shell, and deep-link
handling for the `kikuyomi://` scheme.

## Consequences

Routes become the app's URL vocabulary, which pays off twice: the same route definitions serve
in-app navigation and external deep links, so there is no second parser to keep in sync with the
first. It also makes the desktop build's back and forward behaviour fall out naturally rather than
being simulated.

Being Flutter-team maintained matters for the same reason it mattered for the framework choice:
this is a long-lived project on a part-time budget, and the routing layer is not where the
interesting problems are. A boring, well-supported choice is the right one.

Typed routes are worth the generation step. Passing a book identifier as a `String` through an
untyped route map is precisely the kind of error that shows up as a crash in the field rather than
a compile error, and this app passes identifiers constantly.

**The escape hatch is that routing is confined to `app`.** No package below it knows how
navigation works. Replacing the router means rewriting the route table and the calls that push
routes, which is mechanical, and touching nothing in `domain`, `data` or any of the pure packages.
