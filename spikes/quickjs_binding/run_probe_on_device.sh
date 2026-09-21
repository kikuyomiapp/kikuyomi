#!/usr/bin/env bash
# Runs the qjs_probe APK on the one Android device or emulator adb can see, and judges the result.
#
# Usage: run_probe_on_device.sh <apk> <output dir> [timeout in seconds, default 180]
#
# Installs and launches the probe, waits for its "QJS_PROBE DONE" line in logcat, and saves:
#   probe.txt    the QJS_PROBE lines alone
#   flutter.log  everything the app printed (logcat tag "flutter")
#   logcat.txt   the whole log, for crashes and anything else
#   device.txt   what the device is
#
# Exits 0 only when a DONE line appeared and no probe failed. .github/workflows/android-emulator.yml
# runs it on emulators; it works the same against a phone plugged in over USB.
set -euo pipefail

apk="$1"
out="$2"
timeout="${3:-180}"
package=com.example.qjs_probe

mkdir -p "$out"
adb wait-for-device

prop() { adb shell getprop "$1" | tr -d '\r'; }
{
  echo "api=$(prop ro.build.version.sdk)"
  echo "release=$(prop ro.build.version.release)"
  echo "abi=$(prop ro.product.cpu.abi)"
  echo "model=$(prop ro.product.model)"
  echo "cpus=$(adb shell nproc 2>/dev/null | tr -d '\r' || echo unknown)"
} | tee "$out/device.txt"

adb install -r "$apk"
# A freshly booted emulator logs heavily; a larger ring buffer keeps the first probe lines from
# being overwritten before they are read.
adb logcat -G 16M || true
adb logcat -c
adb shell am start -W -n "$package/.MainActivity"

started=$SECONDS
done_line=''
while (( SECONDS - started < timeout )); do
  adb logcat -d -s flutter:I > "$out/flutter.log" || true
  done_line=$(grep -o 'QJS_PROBE DONE.*' "$out/flutter.log" | tr -d '\r' | tail -n 1 || true)
  [[ -n "$done_line" ]] && break
  sleep 3
done
elapsed=$(( SECONDS - started ))

adb logcat -d > "$out/logcat.txt" || true
grep -o 'QJS_PROBE .*' "$out/flutter.log" | tr -d '\r' > "$out/probe.txt" || true

echo "--- probe output after ${elapsed}s ---"
cat "$out/probe.txt"

verdict=pass
reason=''
if [[ -z "$done_line" ]]; then
  verdict=fail
  last=$(grep 'QJS_PROBE START' "$out/probe.txt" | tail -n 1 || true)
  reason="no DONE line within ${timeout}s; last probe started: ${last:-none}"
elif grep -q '^QJS_PROBE FAIL ' "$out/probe.txt"; then
  verdict=fail
  reason="$done_line"
elif [[ "$done_line" != *" failed=0" ]]; then
  verdict=fail
  reason="$done_line"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### QuickJS probe on API $(prop ro.build.version.sdk): ${verdict}"
    [[ -n "$reason" ]] && echo "" && echo "$reason"
    echo ""
    echo '```'
    cat "$out/probe.txt"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$verdict" != pass ]]; then
  echo "FAILED: $reason" >&2
  exit 1
fi
echo "PASSED: $done_line"
