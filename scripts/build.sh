#!/bin/zsh
# Builds build.noindex/Relay.app and code-signs it. (".noindex" keeps this
# intermediate copy out of Spotlight; only ~/Applications/Relay.app should show up.)
#
# Signing: uses your free "Apple Development" identity if one exists (Xcode ›
# Settings › Accounts › add Apple ID › Manage Certificates › +). That keeps the
# Accessibility grant stable across rebuilds. Otherwise falls back to an ad-hoc
# signature pinned to the bundle identifier.
set -euo pipefail
cd "${0:A:h}/.."

BUNDLE_ID="local.relay.Relay"
APP="build.noindex/Relay.app"

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Relay "$APP/Contents/MacOS/Relay"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp -R web "$APP/Contents/Resources/web"
cp Support/Relay.icns "$APP/Contents/Resources/Relay.icns"
# Extended attributes (Finder info, provenance) on copied files break strict signing.
xattr -cr "$APP"

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
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
