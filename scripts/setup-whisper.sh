#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
archive=$(mktemp -t voice-whisper)
extract=$(mktemp -d -t voice-whisper)
trap 'rm -f "$archive"; rm -rf "$extract"' EXIT
curl --fail --location --retry 3 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip' -o "$archive"
printf '%s  %s\n' af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b "$archive" | shasum -a 256 -c -
unzip -q "$archive" -d "$extract"
mkdir -p Frameworks
rm -rf Frameworks/whisper.xcframework
mv "$extract/build-apple/whisper.xcframework" Frameworks/
echo 'Whisper ready. Open VoiceApp.xcodeproj.'
