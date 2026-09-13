# ADR-0004: Riverpod for state management and dependency injection

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §2.5 and §2.8, decision 5

## Context

Two problems needed solving, and they are usually solved by two libraries: how screens hold and
publish state, and how concrete implementations reach the code that depends on them.

The second is the harder constraint here. Much of this app's work happens **outside the widget
tree**: the playback coordinator runs whether or not a player screen is mounted, downloads
continue with every screen closed, and the `audio_service` handler outlives any route. A
dependency-injection mechanism that can only be reached from a `BuildContext` is not usable for
those.

Testing shapes it too. The pure-Dart packages must be testable with `dart test` in seconds, which
means they cannot import a state-management library at all.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Riverpod** | Solves state and DI together; works outside the widget tree; provider overrides make tests trivial; compile-time safety | Its own vocabulary to learn; two generations of API in circulation | **Chosen** |
| Bloc | Well-established; explicit event/state modelling; good tooling | Needs a separate DI solution such as get_it; more boilerplate per screen | Rejected |
| Provider + get_it | Simple and familiar | Two libraries, two mental models, and `BuildContext` coupling in the first | Rejected |
| Hand-rolled | No dependency | Reinvents override-for-test, which is the feature actually wanted | Rejected |

## Decision

Riverpod for both state management and dependency injection. Providers form the dependency graph,
and the composition root in `app` selects platform adapter implementations at startup and exposes
everything through them.

## Consequences

**The pure-Dart packages never import Riverpod.** They take their dependencies through
constructors like ordinary classes, and the providers that construct them live in `app`. This is
the rule that keeps `domain`, `data` and the rest testable with plain `dart test` and reusable
from a command-line tool. It is easy to violate by accident and worth watching for in review.

Coming from Java, providers are closest to a Spring context: a graph of lazily-constructed
singletons resolved by type, with test configurations overriding beans. The difference is that the
graph is written in Dart rather than annotations or XML, so it is checked by the compiler and
navigable in an IDE.

Provider overrides are the testing story for the app layer: a widget test replaces the repository
provider with a fake and the screen under test never knows. Combined with the fake clock and fake
engine in `test_support`, this is what makes the playback rules deterministic to test.

**The escape hatch is the constructor injection already required of the pure packages.** Because
none of them depend on Riverpod, replacing it means rewriting the provider declarations in `app`
and the notifiers, not the logic underneath. The blast radius is the UI layer.
