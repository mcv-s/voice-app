#!/bin/bash
# Requires a booted iPhone Simulator. Simulator manages its own app container.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/fixtures
curl --fail --location --retry 2 https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin -o build/fixtures/ggml-tiny.en.bin
printf '%s  %s\n' 921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f build/fixtures/ggml-tiny.en.bin | shasum -a 256 -c -
curl --fail --location https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.2/samples/jfk.wav -o build/fixtures/fixture.wav
xcodebuild -project VoiceApp.xcodeproj -scheme voice-app -configuration Debug -sdk iphonesimulator -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/voice-app.app
container=$(xcrun simctl get_app_container booted com.mcvs.voice-app data)
xcrun simctl terminate booted com.mcvs.voice-app 2>/dev/null || true
mkdir -p "$container/Library/Application Support/VoiceApp" "$container/Documents"
cp build/fixtures/ggml-tiny.en.bin "$container/Library/Application Support/VoiceApp/"
cp build/fixtures/fixture.wav "$container/Documents/"
rm -f "$container/Documents/smoke-result.json"
xcrun simctl launch booted com.mcvs.voice-app --transcribe-fixture
for attempt in $(seq 1 60); do
    if [ -f "$container/Documents/smoke-result.json" ]; then
        python3 - "$container/Documents/smoke-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert 'ask not what your country can do for you' in result['text'].lower(), result
print('PASS:', result['text'])
print('Inference seconds:', result['duration'])
PY
        exit 0
    fi
    sleep 1
done
echo 'FAIL: no inference result after 60 seconds' >&2
exit 1
