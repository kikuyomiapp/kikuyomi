# Test fixtures

Both files are **generated**, not taken from any audiobook. Each is 15 seconds of a 220 Hz sine
tone encoded as AAC, carrying three chapters at 0 s, 4 s and 9 s titled "Chapter One", "Chapter
Two" and "Chapter Three". No copyrighted or third-party material is involved, and none may be added
here.

- `sample.m4b` — written by ffmpeg, so it carries chapters **twice**: in a Nero `chpl` atom and in
  a QuickTime chapter track.
- `sample_no_chpl.m4b` — the same file with the four bytes `chpl` overwritten as `free`. `free` is
  a standard skip box of the same size, so the file stays valid and the atom becomes invisible. It
  stands in for a file written by Apple's tools, which produce only the chapter track.

They were produced in spike (d); `spikes/m4b_chapters/fixtures/make.sh` regenerates the first.
