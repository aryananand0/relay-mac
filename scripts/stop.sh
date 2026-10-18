#!/bin/zsh
# Stops Relay until the next login (or ./scripts/install.sh).
launchctl bootout "gui/$(id -u)/local.relay.Relay" 2>/dev/null
pkill -x Relay 2>/dev/null
echo "Relay stopped."
