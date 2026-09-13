# Spike (a), second half: CSS selector coverage in the Dart `html` parser

**Question.** Does `package:html` support the CSS selectors a source extension realistically needs
to scrape a catalogue page? §3.5 makes HTML parsing a host-provided bridge, so whatever this
package can and cannot do becomes part of the extension contract.

**Status: complete.** 20 of 28 probes correct, 3 silently wrong, 5 unsupported.

Run it with `dart pub get && dart run bin/probe.dart`. The fixture is synthetic and has the shape
of a catalogue listing — cards, pagination, a chapter table, a metadata list — without being taken
from or modelled on any real service.

## What works

Everything an extension needs most of the time:

- tag, class, id, descendant, child `>`, and selector groups
- **all three sibling combinators**, including `dt + dd`, which is how "the value next to this
  label" scraping works in practice
- **every attribute operator**: `[a]`, `[a="v"]`, `[a^="v"]`, `[a$="v"]`, `[a*="v"]`, `[a~="v"]`,
  `[a|="v"]`
- `:first-child`, `:last-child`, `:only-child`, `:not(...)`
- deep composites such as `ul#results > li.card > h3.title > a[href^="/book/"]`

## What does not

| Selector | Behaviour |
|---|---|
| `:has(...)` | `UnimplementedError`; `:has(> a)` fails even to parse |
| `:nth-child(2n+1)` | `UnimplementedError` |
| `:nth-of-type(n)` | `UnimplementedError` |
| `:only-of-type` | `UnimplementedError` |
| `:nth-child(odd)` / `(even)` | **Silently matches nothing** |
| `:empty` | **Silently matches nothing** |
| `:nth-child(n)` | **Silently wrong on indented HTML — see below** |

## The `:nth-child` trap

`:nth-child(n)` counts **nodes, not elements**, so whitespace between tags shifts the index. The
same document, formatted two ways:

```
compact (no whitespace): nth-child(1)=1  nth-child(2)=1  first-child=1
pretty (indented):       nth-child(1)=1  nth-child(2)=0  first-child=1
```

Every real page is the second one. An author writes `tr:nth-child(2)`, tests against a minified
sample or gets lucky with index 1, ships, and in production the selector quietly matches nothing.

This is the dangerous failure mode. An `UnimplementedError` is loud and gets fixed during
development. A selector that parses, throws nothing, and returns the wrong set produces a
**silently corrupted library**: missing chapters, absent durations, books that appear to have no
content. It is indistinguishable at the boundary from a site that genuinely returned nothing,
which is exactly the case the merge rules in §4.4 are supposed to treat as "no change".

## Consequences for the extension contract

The architecture already says extension output is untrusted and must be validated at the boundary.
This spike shows the *input* side needs the same suspicion: a selector is untrusted too, and the
host cannot tell a correct empty result from a broken one after the fact.

Three mitigations, and the first two should both happen:

1. **Reject unsupported selectors at the host bridge**, loudly, instead of passing them to
   `querySelectorAll` and returning an empty list. The host knows the supported subset; an
   extension asking for `:has()` or `:empty` should get an error naming the selector, not silence.
2. **Validate selectors in the SDK at build time.** The TypeScript SDK and CLI from Phase 2 can
   parse selector literals and refuse to bundle an extension that uses an unsupported or
   whitespace-fragile one. This catches it before it ever reaches a user.
3. **Document the supported subset as part of SourceAPI**, with `:nth-child` marked unreliable and
   an index-based helper offered in its place. Extension authors will otherwise assume full CSS,
   because every browser they test in has it.

None of this changes the choice of parser. `package:html` covers the selectors that matter, and
the gaps are in the exotic tail. What it changes is that the gaps must be **explicit and
enforced**, not discovered by an extension author whose users are quietly missing chapters.

## Not tested

Malformed real-world HTML, character-encoding edge cases, and parse throughput on large pages.
Throughput matters because §2.7 puts parsing in the worker isolate specifically to keep it off the
UI thread, and that assumption has not been measured.
