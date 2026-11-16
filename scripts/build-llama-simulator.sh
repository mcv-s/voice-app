#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/llama-source build/research
archive=build/research/llama-b12387.tar.gz
checksum=6986a5acc4c851acddcfd06b95d470976dc1aad83f91f191ec2f479f8156fa05
if ! [ -f "$archive" ] || ! printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl --fail --location --retry 3 'https://github.com/ggml-org/llama.cpp/archive/refs/tags/b12387.tar.gz' -o "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C build/llama-source --strip-components=1
if ! [ -x build/tools/bin/cmake ]; then
    python3 -m venv build/tools
    build/tools/bin/pip install --no-cache-dir cmake==4.4.5 ninja==1.13.2
fi
for slice in simulator-arm64 simulator-x86_64 device-arm64; do
    arch="${slice##*-}"
    sdk=iphonesimulator
    if [[ "$slice" == device-* ]]; then sdk=iphoneos; fi
    arm_options=()
    if [ "$arch" = arm64 ]; then arm_options=(-DGGML_CPU_ARM_ARCH=armv8.2-a); fi
    build/tools/bin/cmake -S build/llama-source -B "build/llama-$slice" -G Ninja \
        -DCMAKE_MAKE_PROGRAM="$PWD/build/tools/bin/ninja" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR="$arch" \
        -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_MTMD=OFF -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF \
        "${arm_options[@]}"
    build/tools/bin/cmake --build "build/llama-$slice" --target llama -j 6
done
./scripts/package-llama-simulator.sh

./scripts/package-llama-device.sh
