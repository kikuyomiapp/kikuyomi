#!/usr/bin/env bash
# Regenerates sample.m4b. The fixture is committed, so this is only needed if it changes.
#
# ffmpeg is a BUILD-TIME tool for this fixture only. Nothing in the app depends on it at runtime;
# that is the whole point of spike (d).
#
# The audio is a generated sine tone. No real audiobook is used, and none should be.
set -euo pipefail
cd "$(dirname "$0")"

python - <<'PY'
import struct, math
sr, secs = 44100, 15
data = bytearray()
for i in range(sr * secs):
    data += struct.pack('<h', int(math.sin(2 * math.pi * 220 * i / sr) * 12000))
hdr = (b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt '
       + struct.pack('<IHHIIHH', 16, 1, 1, sr, sr * 2, 2, 16)
       + b'data' + struct.pack('<I', len(data)))
open('tone.wav', 'wb').write(hdr + bytes(data))
PY

ffmpeg -y -i tone.wav -i chapters.txt -map_metadata 1 -map 0:a -c:a aac -b:a 32k sample.m4b
rm -f tone.wav
echo "wrote sample.m4b"
