#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/llama Frameworks
archive=build/llama/llama-b12387-xcframework.zip
checksum=93d4ab674c75d590b6e0650b24683964c61dbbeb6bb94aa8dbed5a61346899f8
if ! [ -f "$archive" ] || ! printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl --fail --location --retry 3 'https://github.com/ggml-org/llama.cpp/releases/download/b12387/llama-b12387-xcframework.zip' -o "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
unzip -qo "$archive" -d build/llama
rm -rf Frameworks/llama.xcframework
cp -R build/llama/build-apple/llama.xcframework Frameworks/llama.xcframework

./scripts/build-llama-simulator.sh
