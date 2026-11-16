#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
framework=Frameworks/llama.xcframework/ios-arm64_x86_64-simulator/llama.framework
mkdir -p "$framework"
cp -R Frameworks/llama.xcframework/ios-arm64/llama.framework/Headers "$framework/"
cp -R Frameworks/llama.xcframework/ios-arm64/llama.framework/Modules "$framework/"
cp Frameworks/llama.xcframework/ios-arm64/llama.framework/Info.plist "$framework/"
python3 - <<'PY'
import subprocess,pathlib
s=subprocess.check_output(['nm','-gU','build/llama-simulator-arm64/src/libllama.a'],text=True)
exports=sorted(set(line.split()[-1] for line in s.splitlines() if ' T _llama_' in line))
pathlib.Path('build/llama-simulator-exports.txt').write_text('\n'.join(exports)+'\n')
PY
for arch in arm64 x86_64; do
    build_dir="$PWD/build/llama-simulator-$arch"
    xcrun --sdk iphonesimulator clang -dynamiclib -target "$arch-apple-ios16.4-simulator" -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
        -Wl,-force_load,"$build_dir/src/libllama.a" \
        -Wl,-force_load,"$build_dir/ggml/src/libggml.a" \
        -Wl,-force_load,"$build_dir/ggml/src/libggml-base.a" \
        -Wl,-force_load,"$build_dir/ggml/src/libggml-cpu.a" \
        -Wl,-dead_strip -Wl,-exported_symbols_list,"$PWD/build/llama-simulator-exports.txt" \
        -install_name @rpath/llama.framework/llama -lc++ -framework Foundation -framework Accelerate \
        -o "build/llama-simulator-$arch.dylib"
    xcrun strip -S "build/llama-simulator-$arch.dylib"
done
xcrun lipo -create build/llama-simulator-arm64.dylib build/llama-simulator-x86_64.dylib -output "$framework/llama"
python3 - <<'PY'
import plistlib,pathlib
p=pathlib.Path('Frameworks/llama.xcframework/Info.plist');data=plistlib.loads(p.read_bytes());identifier='ios-arm64_x86_64-simulator'
data['AvailableLibraries']=[x for x in data['AvailableLibraries'] if x['LibraryIdentifier']!=identifier]
data['AvailableLibraries'].append(dict(LibraryIdentifier=identifier,LibraryPath='llama.framework',SupportedArchitectures=['arm64','x86_64'],SupportedPlatform='ios',SupportedPlatformVariant='simulator'))
p.write_bytes(plistlib.dumps(data))
p=pathlib.Path('Frameworks/llama.xcframework')/identifier/'llama.framework/Info.plist';data=plistlib.loads(p.read_bytes());data['CFBundleSupportedPlatforms']=['iPhoneSimulator'];p.write_bytes(plistlib.dumps(data))
PY
