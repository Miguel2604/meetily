#!/bin/sh
# Builds the asr-helper sidecar and stages it where Tauri bundles external binaries.
set -eu
cd "$(dirname "$0")"
swift build -c release
mkdir -p ../frontend/src-tauri/binaries
cp .build/release/asr-helper ../frontend/src-tauri/binaries/asr-helper-aarch64-apple-darwin
echo "asr-helper staged in frontend/src-tauri/binaries/"
