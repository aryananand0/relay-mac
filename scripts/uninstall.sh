#!/bin/zsh
# Removes the login item and the installed app.
# Keeps your pairing code and log unless you pass --all.
launchctl bootout "gui/$(id -u)/local.relay.Relay" 2>/dev/null
pkill -x Relay 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.relay.Relay.plist"
rm -rf "$HOME/Applications/Relay.app"
if [[ "${1:-}" == "--all" ]]; then
  rm -rf "$HOME/Library/Application Support/Relay" "$HOME/Library/Logs/Relay"
  # Relay's HTTPS certificates and their private keys, in the login Keychain.
  HOST="$(scutil --get LocalHostName)"
  for NAME in "Relay Local CA ($HOST)" "Relay ($HOST)"; do
    while security delete-identity -c "$NAME" >/dev/null 2>&1; do :; done
  done
  defaults delete local.relay.Relay 2>/dev/null
  echo "Relay, its pairing code, certificates, settings and log are removed."
else
  echo "Relay removed (pairing code and log kept; run with --all to remove them too)."
fi
echo "You can also remove Relay from System Settings › Privacy & Security › Accessibility and › Screen & System Audio Recording,"
echo "and remove the Relay profile on your iPhone: Settings › General › VPN & Device Management."
