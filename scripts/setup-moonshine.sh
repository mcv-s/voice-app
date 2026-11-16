#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/moonshine Frameworks
archive=build/moonshine/Moonshine-0.1.6.zip
checksum=ab5adaf75d328eb87db72bc87efb8cf84c7d5220f1c8ed8819a9a85edf3efc33
if ! [ -f "$archive" ] || ! printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl --fail --location --retry 3 'https://github.com/moonshine-ai/moonshine-swift/releases/download/v0.1.6/Moonshine.xcframework.zip' -o "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
unzip -qo "$archive" -d Frameworks
./scripts/isolate-moonshine.sh
echo 'Moonshine runtime ready. Model weights download separately in Settings → Models.'
