#!/bin/zsh
# Builds Relay.app in a private temp folder and code-signs it; install.sh copies it from there.
# Not in this folder: Documents is synced by iCloud, which stamps new folders with attributes
# (Finder info, file-provider tags) a moment after they're created, and that breaks signing.
# The ".noindex" name also keeps this copy out of Spotlight; only ~/Applications/Relay.app
# should show up there.
#
# Signing: uses your free "Apple Development" identity if one exists (Xcode ›
# Settings › Accounts › add Apple ID › Manage Certificates › +). That keeps the
# Accessibility grant stable across rebuilds. Otherwise falls back to an ad-hoc
# signature pinned to the bundle identifier.
set -euo pipefail
cd "${0:A:h}/.."

BUNDLE_ID="local.relay.Relay"
BUILD_DIR="${RELAY_BUILD_DIR:-${TMPDIR:-/tmp}/relay-build.noindex}"
APP="$BUILD_DIR/Relay.app"

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Copy without extended attributes (the sources carry iCloud tags that break strict signing).
copy() { ditto --norsrc --noextattr --noqtn "$1" "$2"; }
copy .build/release/Relay "$APP/Contents/MacOS/Relay"
copy Support/Info.plist "$APP/Contents/Info.plist"
copy web "$APP/Contents/Resources/web"
copy Support/Relay.icns "$APP/Contents/Resources/Relay.icns"
xattr -cr "$APP" 2>/dev/null || true

IDENTITY="${RELAY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  echo "No Apple Development identity found; signing ad-hoc (pinned to $BUNDLE_ID)."
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

# Make sure macOS doesn't list this build copy as a second Relay app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
