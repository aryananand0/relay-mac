#!/bin/zsh
# Opens the QR code for pairing your iPhone (Relay must be running).
# The page needs Relay's per-launch token, readable only by you.
token_file="$HOME/Library/Application Support/Relay/pairing-page-token"
if [[ ! -r "$token_file" ]]; then
  echo "Relay isn't running yet. Start it with ./scripts/install.sh or from ~/Applications." >&2
  exit 1
fi
open "http://localhost:8765/pair?t=$(<"$token_file")"
