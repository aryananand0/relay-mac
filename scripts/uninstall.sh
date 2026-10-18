#!/bin/zsh
# Removes the login item and the installed app. Keeps your pairing code and logs.
launchctl bootout "gui/$(id -u)/local.relay.Relay" 2>/dev/null
pkill -x Relay 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.relay.Relay.plist"
rm -rf "$HOME/Applications/Relay.app"
echo "Relay removed. You can also remove it from System Settings › Privacy & Security › Accessibility."
