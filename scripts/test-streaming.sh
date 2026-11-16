#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Download FastConformer Transducer in the app first. Use a neutral synthesized fixture.
device=$(xcrun simctl list devices booted --json | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["state"]=="Booted" and "iPhone" in d["name"]))')
xcodebuild -project VoiceApp.xcodeproj -scheme voice-app -configuration Debug -destination "platform=iOS Simulator,id=$device" -derivedDataPath build build
xcrun simctl install "$device" build/Build/Products/Debug-iphonesimulator/voice-app.app
container=$(xcrun simctl get_app_container "$device" com.suitbound.game data)
xcrun simctl terminate "$device" com.suitbound.game 2>/dev/null || true
mkdir -p build/fixtures
say -r 150 -o build/fixtures/garden.aiff "Good morning everyone. The community garden meeting starts at ten on Saturday. Please bring a notebook and your ideas. We will choose flowers for the front entrance and make a plan for watering them."
afconvert -f WAVE -d LEF32@16000 -c 1 build/fixtures/garden.aiff build/fixtures/garden.wav
cp build/fixtures/garden.wav "$container/Documents/streaming-fixture.wav"
rm -f "$container/Documents/streaming-result.json"
xcrun simctl launch "$device" com.suitbound.game --streaming-smoke-test
for attempt in $(seq 1 60); do
    if [ -f "$container/Documents/streaming-result.json" ]; then
        cp "$container/Documents/streaming-result.json" build/streaming-result.json
        python3 - <<'PY'
import json
r=json.load(open('build/streaming-result.json'))
assert r.get('passed'), r
assert 'garden' in r['text'].lower() and 'saturday' in r['text'].lower(), r
print(json.dumps(r, indent=2))
PY
        exit 0
    fi
    sleep 1
done
echo 'No test result within 60 seconds' >&2
exit 1
