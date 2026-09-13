# ADR-0009: Categories are manual, collections are rule-based

- **Status:** Accepted
- **Date:** 2026-09-13
- **Relates to:** `docs/architecture.md` §1.4, decision 10

## Context

Users want to group books, and they want it for two incompatible reasons.

Sometimes the grouping is a **decision**: "these are the ones I mean to listen to next", "these are
for the commute". No rule produces that set; the user simply says so, and expects it to stay as
they left it.

Sometimes the grouping is a **query**: "everything by this narrator", "everything I have not
started", "everything downloaded". Maintaining those by hand is tedious and they go stale
immediately.

Mihon offers manual categories only, and users end up hand-maintaining sets that a rule could
compute. Treating both kinds as one concept forces a choice between a manual group that cannot
update itself and a smart group the user cannot pin something into.

There is also a third, narrower case: multi-part works. A trilogy released as three entries is one
thing to the user and three rows in the database.

## Options considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Categories manual, collections rule-based, series grouped automatically** | Each kind of grouping behaves the way its purpose implies | Three concepts to explain and to build | **Chosen** |
| Manual groupings only, as Mihon does | Simplest; familiar | Users hand-maintain what a rule could compute | Rejected |
| Rule-based only | Everything stays current | Cannot express "because I said so", which is the more common case | Rejected |
| One concept with an optional rule | Fewer nouns | The two behave differently on every edge — add, remove, reorder, delete — so the union is confusing | Rejected |

## Decision

**Categories** are manual, many-to-many library tabs, each carrying its own sort, filter and
display settings. **Collections** are rule-based smart groups computed from the library. **Series
grouping** is automatic, from metadata, and is not a category.

## Consequences

Categories being **many-to-many** matters: a book belongs to as many as the user likes, which is
what makes them tabs rather than folders and avoids the "where did I file it" problem. Per-category
settings mean a "Short listens" tab can sort by duration while "Next up" sorts by date added,
which is most of the value of having tabs at all.

Collections being computed means they are **derived state, never stored membership**. They are
queries over the library, which fits the single-source-of-truth rule exactly: a book that becomes
eligible appears without anything being written. It also means a collection can never be edited
directly, and the UI must make that obvious rather than offering a remove action that silently
does nothing.

The cost is genuine: three grouping concepts is more surface than one, in the data model, the
settings UI and the documentation. The bet is that the distinction is one users already hold in
their heads, so naming it is cheaper than collapsing it.

Series grouping is deliberately **not** user-editable in the first version. It comes from source
metadata, which will sometimes be wrong, and the fix is metadata editing rather than a fourth
grouping mechanism.
