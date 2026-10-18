#!/bin/zsh
# Installs Relay to ~/Applications and starts it now and at every login.
# Re-run after changing the code to update the installed copy.
set -euo pipefail
cd "${0:A:h}/.."

LABEL="local.relay.Relay"
APP="$HOME/Applications/Relay.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LOG="$HOME/Library/Logs/Relay/relay.log"

./scripts/build.sh

# Stop whatever is running (installed agent or a copy started by hand).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x Relay 2>/dev/null || true

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
ditto --norsrc --noextattr --noqtn build.noindex/Relay.app "$APP"
# Only the installed copy should exist as an app (Spotlight, Open With, Login Items),
# so the build copy is removed once it's been copied.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/build.noindex/Relay.app" 2>/dev/null || true
rm -rf build.noindex

# KeepAlive/SuccessfulExit=false: restart Relay if it crashes, but not after a clean stop.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/Relay</string>
	</array>
	<key>AssociatedBundleIdentifiers</key>
	<string>$LABEL</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>/dev/null</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/Relay/relay-stderr.log</string>
</dict>
</plist>
EOF

START_LINE=$(( $( [[ -f "$LOG" ]] && wc -l < "$LOG" || echo 0 ) + 1 ))
launchctl bootstrap "$DOMAIN" "$PLIST"

for _ in {1..20}; do
  sleep 0.25
  tail -n +"$START_LINE" "$LOG" 2>/dev/null | grep -q "QR code to scan" && break
done
tail -n +"$START_LINE" "$LOG"
echo
echo "Relay is installed at $APP and starts automatically when you log in."
echo "Pair your iPhone: ./scripts/pair.sh    Stop: ./scripts/stop.sh    Remove: ./scripts/uninstall.sh"
