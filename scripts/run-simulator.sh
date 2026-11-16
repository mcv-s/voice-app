#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device=$(xcrun simctl list devices booted --json | python3 -c 'import json,sys; devices=[d for group in json.load(sys.stdin)["devices"].values() for d in group if d["state"] == "Booted" and "iPhone" in d["name"]]; print(devices[0]["udid"] if devices else "")')
if [ -z "$device" ]; then
    echo 'Boot an iPhone simulator in Xcode first, then run this script again.' >&2
    exit 1
fi
xcodebuild -project VoiceApp.xcodeproj -scheme voice-app -configuration Debug -destination "platform=iOS Simulator,id=$device" -derivedDataPath build build
xcrun simctl install "$device" build/Build/Products/Debug-iphonesimulator/voice-app.app
xcrun simctl terminate "$device" com.mcvs.voice-app 2>/dev/null || true
xcrun simctl launch "$device" com.mcvs.voice-app
