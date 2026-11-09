#!/bin/zsh
# Runs Relay's checks. The crypto check needs only Node; the rest talk to the installed,
# running Relay: security (pairing, encryption, web server), cursor movement, scrolling,
# typing into a test window, volume (restored), keep awake / sleep timer (dry run), the
# clipboard (restored), find my cursor, and the screen preview.
# Pass --display to also turn the display off for ~2 s and wake it.
set -euo pipefail
cd "${0:A:h}"
OUT="${TMPDIR:-/tmp}/relay-tools"; mkdir -p "$OUT"
CODE="$(cat ~/Library/Application\ Support/Relay/pairing-code)"

# Each tool is a single script; it's compiled together with the shared encrypted client.
for t in securitytest movetest smoothtest scrolltest typetest volumetest powertest previewtest displaytest; do
  if [[ ! "$OUT/$t" -nt "$t.swift" || ! "$OUT/$t" -nt RelayClient.swift ]]; then
    mkdir -p "$OUT/src-$t"; cp "$t.swift" "$OUT/src-$t/main.swift"
    swiftc -O "$OUT/src-$t/main.swift" RelayClient.swift -o "$OUT/$t" 2>&1 | grep -E "error" || true
  fi
done
echo "== crypto (web/crypto.js vs Node)"; node cryptotest.mjs
echo "== phone crypto ↔ Mac"; NODE_EXTRA_CA_CERTS="$HOME/Library/Application Support/Relay/tls/relay-ca.pem" node interoptest.mjs "$CODE" | tail -1
echo "== security";         "$OUT/securitytest" "$CODE" | tail -1
echo "== cursor movement";  "$OUT/movetest" "$CODE" | tail -1
echo "== smoothness";       "$OUT/smoothtest" "$CODE" 0 0; "$OUT/smoothtest" "$CODE" 1 4
echo "== scrolling";        "$OUT/scrolltest" "$CODE" | tail -1
echo "== typing";           "$OUT/typetest" "$CODE" | tail -1
echo "== volume";           "$OUT/volumetest" "$CODE" | tail -1
echo "== power, clipboard, find cursor"; "$OUT/powertest" "$CODE" | tail -1
echo "== screen preview";   "$OUT/previewtest" "$CODE" | tail -1
if [[ "${1:-}" == "--display" ]]; then echo "== display off/wake"; "$OUT/displaytest" "$CODE"; fi
