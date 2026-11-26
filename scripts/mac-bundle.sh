#!/bin/sh
# Xcode build phase, Mac Catalyst only: puts what a Mac that serves needs into Lantern.app.
#
#   Contents/MacOS/lantern-bridge                          Bridge/ (Go), built here
#   Contents/Library/LaunchAgents/<bundle id>.bridge.plist the agent that runs it at login and
#                                                          while Lantern is closed (MacServer
#                                                          registers it with SMAppService)
#
# Both go in before the app is signed, so its signature seals them. A Debug build is another
# app (bundle ID ending in .dev): its agent gets a label, folder and port of its own.
set -e
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$PATH"
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
bridge="$contents/MacOS/lantern-bridge"
label="$PRODUCT_BUNDLE_IDENTIFIER.bridge"
plist="$contents/Library/LaunchAgents/$label.plist"
mkdir -p "$contents/MacOS" "$contents/Library/LaunchAgents"

# Only Apple silicon serves, so only arm64 is built.
(cd "$SRCROOT/Bridge" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o "$bridge" .)
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  stamp=--timestamp=none; [ "$CONFIGURATION" = Release ] && stamp=--timestamp
  codesign --force --options runtime $stamp -i "$label" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$bridge"
fi

rm -f "$contents/Library/LaunchAgents/"*.plist
cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/lantern-bridge</string>
	<key>ProgramArguments</key>
	<array>
		<string>lantern-bridge</string>
		<string>serve</string>
	</array>
	<key>AssociatedBundleIdentifiers</key>
	<string>$PRODUCT_BUNDLE_IDENTIFIER</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
EOF
case "$PRODUCT_BUNDLE_IDENTIFIER" in
  *.dev)
    # The bridge's own folder is the installed Lantern's. A launchd plist can't say "~", and a
    # Debug build only runs on the Mac that built it, so this one names the folder outright.
    # It uses the Splash already serving on :8000 instead of starting a second Inkling.
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" \
      -c "Add :EnvironmentVariables:LANTERN_BRIDGE_DIR string $HOME/Library/Application Support/Lantern Dev/Bridge" \
      -c "Add :EnvironmentVariables:LANTERN_BRIDGE_UPSTREAM string ${LANTERN_DEV_UPSTREAM:-http://127.0.0.1:8000}" "$plist"
    ;;
esac
