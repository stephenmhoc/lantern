#!/bin/sh
# Signs an exported Lantern.app again from the inside out, every piece with the Developer ID, the
# hardened runtime and a secure timestamp (notarization wants all three on everything that runs),
# then checks it the way Gatekeeper will. Used by .github/workflows/release-mac.yml after the
# Developer ID export; runnable on its own:
#
#   scripts/mac-sign.sh build/mac-export/Lantern.app ["Developer ID Application"]
#
# Inside out: Sparkle's XPC services, Autoupdate, Updater.app and framework, MacSupport.bundle,
# lantern-bridge (with its LaunchAgent's label as its identifier), then the app with the
# entitlements it was exported with (iCloud) and its embedded Developer ID profile.
set -eu
APP=$1
ID=${2:-Developer ID Application}
SUPPORT="$APP/Contents/PlugIns/MacSupport.bundle"
SPARKLE="$SUPPORT/Contents/Frameworks/Sparkle.framework/Versions/B"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")

sign() { codesign --force --options runtime --timestamp --sign "$ID" "$@"; }

for piece in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/XPCServices/Downloader.xpc"; do
  [ -e "$piece" ] && sign --preserve-metadata=entitlements "$piece"
done
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$SUPPORT/Contents/Frameworks/Sparkle.framework"
sign "$SUPPORT"
sign -i "$BUNDLE_ID.bridge" "$APP/Contents/MacOS/lantern-bridge"
sign --preserve-metadata=entitlements,requirements,flags "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "iCloud.com.merimerimeri.Lantern" \
  || { echo "mac-sign: the app lost its iCloud entitlement" >&2; exit 1; }
for piece in "$APP" "$APP/Contents/MacOS/lantern-bridge" "$SUPPORT" "$SPARKLE/Autoupdate"; do
  codesign -dvv "$piece" 2>&1 | grep -q "^Timestamp=" || { echo "mac-sign: no secure timestamp on $piece" >&2; exit 1; }
  codesign -dvv "$piece" 2>&1 | grep -q "flags=.*runtime" || { echo "mac-sign: no hardened runtime on $piece" >&2; exit 1; }
done
echo "mac-sign: $APP signed inside out with $ID"
