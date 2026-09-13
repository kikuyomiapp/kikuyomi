# ADR-0014: Apache-2.0 licence

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §7.1, decision 12

## Context

The project is open source, has a public extension API, and operates in a content area where §7.1
counsels care. The licence has to serve three audiences at once: contributors, extension authors
writing against `source_api`, and the project itself.

Mangayomi, the closest Flutter precedent, is Apache-2.0. Mihon is Apache-2.0. That is not a reason
on its own, but licence compatibility with the projects most likely to share ideas and code has
practical value.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Apache-2.0** | Permissive; **explicit patent grant**; requires notice of modification; compatible with GPLv3 in one direction; what Mihon and Mangayomi use | Does not compel downstream forks to publish source | **Chosen** |
| MIT | Shortest and most familiar | No patent grant, and no explicit contribution terms | Rejected |
| GPLv3 | Forks must stay open | Deters some contributors; complicates any future store edition; strong copyleft on a public plug-in API creates questions this project does not need | Rejected |
| AGPLv3 | Strongest reciprocity | Aimed at network services, which this is not | Rejected |

## Decision

Apache-2.0, for the application and for `source_api`.

## Consequences

The **patent grant** is the substantive difference from MIT and the reason for the choice. Both
contributors and users receive an explicit grant, and the grant terminates for anyone who brings a
patent claim against the project. For a media-adjacent application this is worth having in writing
rather than implied.

Apache-2.0 permits closed forks. That is accepted deliberately: the alternative is copyleft, and
copyleft on a project whose defining feature is a **public plug-in API** raises questions about
where the licence boundary falls for extensions. Permissive licensing makes that a non-question,
which matters more here than preventing a fork nobody is asking for.

Licensing `source_api` the same way means extension authors face no ambiguity about writing
against the contract, and none about the licence of what they produce. Their extensions are
theirs.

The requirement to state changes in modified files is a real obligation on forks and is worth
keeping in mind when vendoring third-party code into this repository — the `flutter_qjs` fork
contemplated in ADR-0001 is MIT, which is compatible, but the vendored copy must keep its own
notice.

This decision is settled and is recorded here only so the reasoning is not lost. It is not
expected to be revisited.
