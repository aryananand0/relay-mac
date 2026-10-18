#!/bin/zsh
# Runs Relay's Mac-side checks against the installed, running Relay.
# Moves the cursor, scrolls, types into its own test window, and nudges the volume
# (restoring it). Pass --display to also turn the display off for ~2 s and wake it.
set -euo pipefail
cd "${0:A:h}"
OUT="${TMPDIR:-/tmp}/relay-tools"; mkdir -p "$OUT"
CODE="$(cat ~/Library/Application\ Support/Relay/pairing-code)"
for t in movetest smoothtest scrolltest typetest volumetest displaytest; do
  [[ "$OUT/$t" -nt "$t.swift" ]] || swiftc -O "$t.swift" -o "$OUT/$t" 2>/dev/null
done
echo "== cursor movement";  "$OUT/movetest" "$CODE" | tail -1
echo "== smoothness";       "$OUT/smoothtest" "$CODE" 0 0; "$OUT/smoothtest" "$CODE" 1 4
echo "== scrolling";        "$OUT/scrolltest" "$CODE" | tail -1
echo "== typing";           "$OUT/typetest" "$CODE" | tail -1
echo "== volume";           "$OUT/volumetest" "$CODE" | tail -1
if [[ "${1:-}" == "--display" ]]; then echo "== display off/wake"; "$OUT/displaytest" "$CODE"; fi
