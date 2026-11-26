#!/bin/sh
# The app's end-to-end check, in the simulator: launch, ask a question, get an answer, retry it,
# reopen the chat and ask a follow-up (EndToEnd in Lantern/Views/DebugLaunch.swift).
#
#   scripts/e2e.sh          this device's model (Gemma 4 E2B: the simulator runs it on the CPU)
#   scripts/e2e.sh --mac    the paired Mac instead (the simulator must already be paired)
#
# Needs a booted simulator (E2E_DEVICE, default "booted") and, for the on-device run, the E2B
# files in Models/ (weights, drafter, projector), which are cloned into the app's Documents.
set -e
cd "$(dirname "$0")/.."
DEVICE=${E2E_DEVICE:-booted}
APP=com.merimerimeri.Lantern
ARGS="-e2e -model e2b"
[ "$1" = "--mac" ] && ARGS="$ARGS -mac"

if [ "$DEVICE" = booted ]; then
  DEVICE=$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)
  [ -n "$DEVICE" ] || { echo "E2E: no booted simulator"; exit 1; }
fi

xcodegen generate >/dev/null
xcodebuild -project Lantern.xcodeproj -scheme Lantern -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/dd build -quiet
xcrun simctl install "$DEVICE" build/dd/Build/Products/Debug-iphonesimulator/Lantern.app

if [ "$1" != "--mac" ]; then
  DOCS="$(xcrun simctl get_app_container "$DEVICE" $APP data)/Documents"
  for f in gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf mtp-gemma-4-E2B-it.gguf gemma-4-E2B-it-qat-mmproj-F16.gguf; do
    [ -f "$DOCS/$f" ] || cp -c "${MODELS:-Models}/$f" "$DOCS/$f"
  done
fi

xcrun simctl terminate "$DEVICE" $APP >/dev/null 2>&1 || true
LOG=$(mktemp)
# The app keeps running after the check: read its output until the last line, then stop it.
xcrun simctl launch --console-pty "$DEVICE" $APP $ARGS >"$LOG" 2>&1 &
for _ in $(seq 1 600); do
  grep -q "^E2E done" "$LOG" && break
  sleep 1
done
xcrun simctl terminate "$DEVICE" $APP >/dev/null 2>&1 || true
grep "^E2E" "$LOG" || { echo "E2E: no output"; exit 1; }
grep -q "^E2E done: ok" "$LOG"
