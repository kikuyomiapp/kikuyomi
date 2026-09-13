# Spike (d): M4B chapter extraction

**Question.** Can embedded chapter markers be read out of an M4B in pure Dart, with no platform
plugin and no ffmpeg at runtime?

**Status: complete, both chapter formats. Answer: yes, and cheaply.**

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

## Both chapter formats are implemented

M4B stores chapters in two entirely different places, and files carry one or both:

- **`moov/udta/chpl`** — a Nero extension. Simple, flat, written by ffmpeg and most taggers.
  Read by `bin/probe.dart`.
- **A QuickTime chapter track** — an ordinary MP4 track of timed text, referenced from the audio
  track through `tref/chap`. Read by `bin/qt_chapters.dart`.

Supporting only `chpl` would have been a quiet disaster, because **Apple's own tools write only
the chapter track**. Such a file would report "no chapters" and a twenty-hour book would be
presented as one undivided item.

The chapter track is genuinely more work. There is no list of chapters anywhere; it has to be
reconstructed from the sample tables:

```
mdia/mdhd            -> timescale
mdia/minf/stbl/stts  -> per-sample durations (run-length encoded); cumulative sum = start times
mdia/minf/stbl/stsz  -> per-sample byte sizes
mdia/minf/stbl/stsc  -> how many samples live in each chunk
mdia/minf/stbl/stco  -> file offset of each chunk
each sample          -> uint16 length, then that many UTF-8 bytes, then optional trailing atoms
```

Both readers were run against the same file and **agree exactly**: 0.000 s, 4.000 s, 9.000 s with
identical titles.

The fallback was then proved rather than assumed. `fixtures/sample_no_chpl.m4b` is the same file
with the four bytes `chpl` overwritten as `free` — a standard skip box of identical size, so the
file stays valid and the atom becomes invisible. Against it the `chpl` reader correctly reports
nothing while the chapter-track reader still returns all three chapters. That is the Apple-written
case, simulated exactly.

Cost: 985 bytes read of 65,109 (1.51%), still seek-based, still nothing loaded into memory.

## Consequences for the design

- Chapter extraction belongs in a **pure-Dart package** with no platform adapter. `data` or a
  small dedicated package; nothing needs to be written per platform.
- The reader **must** be seek-based. This should be stated wherever the local source is specified,
  because the in-memory version works perfectly on a test fixture and dies on a real book, which
  is the worst possible failure profile.
- **Both readers are required.** Try `chpl` first because it is cheaper, fall back to the chapter
  track, and treat "neither present" as a single-chapter book rather than an error.
- Files carrying both formats need a precedence rule. They agree here, but nothing guarantees it,
  and disagreement should be logged rather than silently resolved.

## Not covered

Files with neither format, malformed and truncated files, non-ASCII chapter titles, chapter times
that disagree between the two formats, 64-bit box sizes (the `largesize` variant, which a file
over 4 GB requires), the `co64` variant of `stco` that such a file also requires, and performance
against a genuinely large file rather than a 65 KB fixture.

`co64` is the one most likely to bite: any M4B over 4 GB uses 64-bit chunk offsets, and the
current reader would misparse it rather than fail cleanly.

## Reproducing

The fixture is committed. To regenerate it you need `ffmpeg` on PATH — a build-time tool for the
fixture only, never a runtime dependency:

```
./fixtures/make.sh
dart pub get
dart run bin/probe.dart fixtures/sample.m4b            # chpl reader
dart run bin/qt_chapters.dart fixtures/sample.m4b      # QuickTime chapter track reader
dart run bin/qt_chapters.dart fixtures/sample_no_chpl.m4b   # the Apple-written case
```
