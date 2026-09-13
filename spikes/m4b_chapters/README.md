# Spike (d): M4B chapter extraction

**Question.** Can embedded chapter markers be read out of an M4B in pure Dart, with no platform
plugin and no ffmpeg at runtime?

**Status: complete. Answer: yes, and cheaply.**

This matters more than it looks. §1.5 lists "one large file with embedded chapter markers" as one
of the four real-world layouts the Timeline must represent, and §2.4 wants this logic in a
pure-Dart package. Had extraction required a native dependency it would have had to live behind a
platform adapter and be written three times, once per platform, with three sets of bugs. It does
not.

## Result

```
file: fixtures/sample.m4b (65109 bytes)
QuickTime chapter track present: true

chpl chapters: 3
  00:00:00.000  Chapter One
  00:00:04.000  Chapter Two
  00:00:09.000  Chapter Three

seek-based reader:
  bytes read: 431 of 65109 (0.66%)
  identical to in-memory result: true
```

Boundaries and titles are exact against a fixture generated with known chapter times.

## The `chpl` layout, confirmed by hand

MP4 is a tree of length-prefixed boxes. Nero-style chapters live at `moov/udta/chpl`, and the
layout was decoded byte by byte from a generated file rather than taken from documentation:

```
version(1) flags(3) reserved(4) count(1)
then per chapter:  start(8 bytes, in 100-nanosecond units)  titleLength(1)  title(UTF-8)
```

The 100-nanosecond unit is the part worth remembering: 10,000 ticks per millisecond. Chapter two
of the fixture reads `0x02625A00` = 40,000,000 ticks = 4.000 s, which is what generated it.

## Read by seeking, never by loading

Real audiobooks are hundreds of megabytes to over a gigabyte. `File.readAsBytes` on a 1 GB M4B is
an out-of-memory crash on a phone, so the probe implements the reader twice and compares:

| | in-memory | seek-based |
|---|---|---|
| bytes read | 65,109 (100%) | **431 (0.66%)** |
| time | 7358 us | **1474 us** |
| result | 3 chapters | identical |

Because MP4 boxes declare their own size, the walker skips the audio payload entirely: it reads
8-byte headers and jumps. The bytes read are a function of the box tree, not the file size, so a
1 GB book costs the same few hundred bytes as this 65 KB one. **The production reader must be the
seek-based one.**

## The gap: two chapter formats exist, and only one is implemented

The fixture carries chapters **twice**: the `chpl` atom this parser reads, and a QuickTime chapter
track — a second `trak` of timed text, referenced from the audio track through `tref/chap`. The
probe detects the latter but does not parse it.

That is the main piece of remaining work, and it is not optional. `chpl` is a Nero extension that
ffmpeg and many taggers write, but **Apple's own tools write only the QuickTime chapter track**,
and a good deal of M4B content in the wild comes from that lineage. A reader that only understands
`chpl` will silently report "no chapters" for those files and fall back to treating a 20-hour book
as one undivided item.

Parsing the text track is more work than `chpl`: it means reading `stts` for durations, `stsz` for
sample sizes and `stco` for chunk offsets, then pulling each title from the sample data. All of it
is still pure Dart and still seek-based.

## Consequences for the design

- Chapter extraction belongs in a **pure-Dart package** with no platform adapter. `data` or a
  small dedicated package; nothing needs to be written per platform.
- The reader **must** be seek-based. This should be stated wherever the local source is specified,
  because the in-memory version works perfectly on a test fixture and dies on a real book, which
  is the worst possible failure profile.
- Support for the QuickTime chapter track is required before the Local source ships in Phase 1.
- Files carrying both formats need a precedence rule. They agree here, but nothing guarantees it,
  and disagreement should be logged rather than silently resolved.

## Not covered

The QuickTime chapter track parser, files with neither format, malformed and truncated files,
non-ASCII chapter titles, chapter times that disagree between the two formats, 64-bit box sizes
(the `largesize` variant, which a file over 4 GB requires), and performance against a genuinely
large file rather than a 65 KB fixture.

## Reproducing

The fixture is committed. To regenerate it you need `ffmpeg` on PATH — a build-time tool for the
fixture only, never a runtime dependency:

```
./fixtures/make.sh
dart pub get
dart run bin/probe.dart fixtures/sample.m4b
```
