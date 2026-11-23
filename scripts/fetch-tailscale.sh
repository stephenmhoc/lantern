#!/bin/sh
# Builds TailscaleKit.xcframework (device + simulator) from a pinned libtailscale into Vendor/.
# Needs Go (brew install go). Afterwards: xcodegen generate.
set -eu
COMMIT=dacde75057ff350e146505829beff446e6823966
cd "$(dirname "$0")/.."
[ -d Vendor/TailscaleKit.xcframework ] && [ "$(cat Vendor/.tailscale 2>/dev/null)" = "$COMMIT" ] && exit 0
command -v go >/dev/null || { echo "Go is required: brew install go" >&2; exit 1; }
WORK=$(mktemp -d)
git clone -q https://github.com/tailscale/libtailscale "$WORK/libtailscale"
git -C "$WORK/libtailscale" checkout -q "$COMMIT"
make -C "$WORK/libtailscale/swift" ios-fat
mkdir -p Vendor && rm -rf Vendor/TailscaleKit.xcframework
cp -R "$WORK/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework" Vendor/
echo "$COMMIT" > Vendor/.tailscale
rm -rf "$WORK"
echo "Vendor/TailscaleKit.xcframework ready"
