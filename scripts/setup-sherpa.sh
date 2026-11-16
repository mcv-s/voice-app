#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/sherpa Frameworks build/legacy-bundled-zipformer
fetch() {
    local url="$1" destination="$2" checksum="$3"
    if [ -f "$destination" ] && printf '%s  %s\n' "$checksum" "$destination" | shasum -a 256 -c - >/dev/null 2>&1; then return; fi
    curl --fail --location --retry 3 "$url" -o "$destination"
    printf '%s  %s\n' "$checksum" "$destination" | shasum -a 256 -c -
}
fetch 'https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.1-ios-static.xcframework.zip' build/sherpa/sherpa.zip 88aa569f71b7903e0bbdfbe6e2e114b3b95862b1ef0759eea3024f82926d7374
fetch 'https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-ios-static-xcframework-1.28.2.xcframework.zip' build/sherpa/ort.zip 2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599
fetch 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26-mobile.tar.bz2' build/sherpa/model.tar.bz2 4dad6f4849cad551042eb875505b3fdc0fac9f1c88d709165c48b921681e61dc
unzip -qo build/sherpa/sherpa.zip -d Frameworks
unzip -qo build/sherpa/ort.zip -d Frameworks
mkdir -p build/sherpa/extracted
tar -xjf build/sherpa/model.tar.bz2 -C build/sherpa/extracted
model_dir=build/sherpa/extracted/sherpa-onnx-streaming-zipformer-en-2023-06-26-mobile
cp "$model_dir/encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx" build/legacy-bundled-zipformer/encoder.int8.onnx
cp "$model_dir/decoder-epoch-99-avg-1-chunk-16-left-128.onnx" build/legacy-bundled-zipformer/decoder.onnx
cp "$model_dir/joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx" build/legacy-bundled-zipformer/joiner.int8.onnx
cp "$model_dir/tokens.txt" build/legacy-bundled-zipformer/tokens.txt
echo 'Native frameworks ready. Choose and download a model in app setup.'
