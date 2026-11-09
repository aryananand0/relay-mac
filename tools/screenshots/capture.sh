#!/bin/zsh
# Captures the README screenshots from the real phone page, with a simulated Mac
# (demo-mac.js) supplying made-up data. Needs Google Chrome and Python 3.
#   tools/screenshots/capture.sh        → docs/assets/*.png
set -euo pipefail
ROOT="${0:A:h}/../.."
SITE="$(mktemp -d)"; OUT="$ROOT/docs/assets"; mkdir -p "$OUT"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT=8799

cp -R "$ROOT/web/." "$SITE/"
cp "${0:A:h}/demo-mac.js" "${0:A:h}/compose.html" "$SITE/"
# Load the simulated Mac before the app script; everything else is the real page.
sed -i '' 's|<script src="relay.js"></script>|<script src="demo-mac.js"></script><script src="relay.js"></script>|' "$SITE/index.html"

python3 -m http.server $PORT --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$SITE"' EXIT
sleep 1

shoot() {  # name width height url
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --default-background-color=00000000 --window-size="$2,$3" --virtual-time-budget=8000 \
    --user-data-dir="$SITE/profile-$1" --screenshot="$SITE/$1.png" "$4" >/dev/null 2>&1
}
# Each image frames the real page at exact phone size (Chrome won't make a window that narrow).
C="http://127.0.0.1:$PORT/compose.html"
shoot relay-hero 1480 1040 "$C?shots=remote,preview,mac&feature=1"
shoot relay-trackpad 480 940 "$C?shots=trackpad"
shoot relay-screens 480 940 "$C?shots=screens"
shoot relay-remote-mac 920 940 "$C?shots=remote,mac"
shoot relay-landscape 940 480 "$C?shots=landscape"

rm -f "$OUT"/relay-*.png(N)
for f in relay-hero relay-trackpad relay-screens relay-remote-mac relay-landscape; do cp "$SITE/$f.png" "$OUT/$f.png"; done
ls -l "$OUT"
