#!/bin/bash
# Builds Vela for the simulator and captures voice, chat and settings.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodebuild \
  -project Vela.xcodeproj \
  -scheme Vela \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build-sim \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  build

APP=$(find build-sim/Build/Products -type d -name 'Vela.app' | head -1)
test -d "$APP"
echo "App: $APP"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
best = None
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable"):
            continue
        name = device.get("name", "")
        if "iPhone" not in name:
            continue
        score = 0
        if "Pro Max" in name:
            score += 10
        elif "Pro" in name:
            score += 5
        if best is None or score > best[0]:
            best = (score, device["udid"], name)
if not best:
    raise SystemExit("no iPhone simulator")
print(best[1])
print(best[2], file=sys.stderr)
')

echo "Simulator $UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b || sleep 8

if ! xcrun simctl install "$UDID" "$APP"; then
  codesign --force --deep --sign - "$APP" || true
  xcrun simctl install "$UDID" "$APP"
fi

xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 || true

mkdir -p screenshots
capture() {
  local name="$1"
  local arg="$2"
  xcrun simctl terminate "$UDID" de.barczewski.vela || true
  xcrun simctl launch "$UDID" de.barczewski.vela --vela-screenshot "$arg"
  sleep 4
  xcrun simctl io "$UDID" screenshot "screenshots/${name}.png"
  echo "captured ${name}"
}

capture voice-nebula voice-0
capture voice-blackhole voice-1
capture voice-nebula-disk voice-2
capture chat chat
capture settings settings

xcrun simctl shutdown "$UDID" || true
ls -la screenshots
