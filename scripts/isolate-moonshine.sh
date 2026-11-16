#!/bin/bash
# Moonshine embeds ORT 1.23, while sherpa uses ORT 1.28. Hide Moonshine's copy
# inside a dynamic framework so C++ globals and the C API cannot interpose.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/moonshine-isolated
cat > build/moonshine-isolated/exports.txt <<'SYMBOLS'
_moonshine_load_transcriber_from_files
_moonshine_free_transcriber
_moonshine_create_stream
_moonshine_free_stream
_moonshine_start_stream
_moonshine_stop_stream
_moonshine_transcribe_add_audio_to_stream
_moonshine_transcribe_stream
_moonshine_error_to_string
SYMBOLS
build_slice() {
    local sdk="$1" target="$2" slice="$3" arch="$4"
    local framework="build/moonshine-isolated/$slice/Moonshine.framework"
    mkdir -p "$framework/Headers" "$framework/Modules"
    cp "Frameworks/Moonshine.xcframework/$slice/Headers/moonshine-c-api.h" "$framework/Headers/"
    printf 'framework module Moonshine { umbrella header "moonshine-c-api.h" export * }\n' > "$framework/Modules/module.modulemap"
    cat > "$framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.moonshine.voice.isolated</string><key>CFBundleName</key><string>Moonshine</string><key>CFBundleExecutable</key><string>Moonshine</string><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleShortVersionString</key><string>0.1.6</string><key>CFBundleVersion</key><string>1</string><key>MinimumOSVersion</key><string>16.4</string></dict></plist>
PLIST
    xcrun --sdk "$sdk" clang -dynamiclib -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        -Wl,-force_load,"$PWD/Frameworks/Moonshine.xcframework/$slice/libmoonshine.a" \
        -Wl,-dead_strip -Wl,-exported_symbols_list,"$PWD/build/moonshine-isolated/exports.txt" \
        -install_name @rpath/Moonshine.framework/Moonshine -lc++ -framework Foundation -framework Accelerate \
        -o "$framework/Moonshine-$arch"
    xcrun strip -S "$framework/Moonshine-$arch"
}
build_slice iphoneos arm64-apple-ios16.4 ios-arm64 arm64
build_slice iphonesimulator arm64-apple-ios16.4-simulator ios-arm64_x86_64-simulator arm64
build_slice iphonesimulator x86_64-apple-ios16.4-simulator ios-arm64_x86_64-simulator x86_64
mv build/moonshine-isolated/ios-arm64/Moonshine.framework/Moonshine-arm64 build/moonshine-isolated/ios-arm64/Moonshine.framework/Moonshine
xcrun lipo -create build/moonshine-isolated/ios-arm64_x86_64-simulator/Moonshine.framework/Moonshine-arm64 build/moonshine-isolated/ios-arm64_x86_64-simulator/Moonshine.framework/Moonshine-x86_64 -output build/moonshine-isolated/ios-arm64_x86_64-simulator/Moonshine.framework/Moonshine
rm build/moonshine-isolated/ios-arm64_x86_64-simulator/Moonshine.framework/Moonshine-arm64 build/moonshine-isolated/ios-arm64_x86_64-simulator/Moonshine.framework/Moonshine-x86_64
rm -rf Frameworks/MoonshineIsolated.xcframework
xcodebuild -create-xcframework -framework build/moonshine-isolated/ios-arm64/Moonshine.framework -framework build/moonshine-isolated/ios-arm64_x86_64-simulator/Moonshine.framework -output "$PWD/Frameworks/MoonshineIsolated.xcframework"
