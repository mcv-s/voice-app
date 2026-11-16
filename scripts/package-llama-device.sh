#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$PWD/build/llama-device-arm64"
framework=Frameworks/llama.xcframework/ios-arm64/llama.framework
xcrun --sdk iphoneos clang -dynamiclib -target arm64-apple-ios16.4 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -Wl,-force_load,"$build_dir/src/libllama.a" \
    -Wl,-force_load,"$build_dir/ggml/src/libggml.a" \
    -Wl,-force_load,"$build_dir/ggml/src/libggml-base.a" \
    -Wl,-force_load,"$build_dir/ggml/src/libggml-cpu.a" \
    -Wl,-dead_strip -Wl,-exported_symbols_list,"$PWD/build/llama-simulator-exports.txt" \
    -install_name @rpath/llama.framework/llama -lc++ -framework Foundation -framework Accelerate \
    -o build/llama-device.dylib
xcrun strip -S build/llama-device.dylib
cp build/llama-device.dylib "$framework/llama"
# CPU builds do not need the original GPU shader payload.
find "$framework" -name '*.metallib' -delete
rm -rf "$framework/_CodeSignature"

python3 - <<'PYINFO'
import pathlib,plistlib
p=pathlib.Path('Frameworks/llama.xcframework/Info.plist');data=plistlib.loads(p.read_bytes())
for library in data['AvailableLibraries']:
    if library['LibraryIdentifier']=='ios-arm64':library.pop('DebugSymbolsPath',None)
p.write_bytes(plistlib.dumps(data))
PYINFO
