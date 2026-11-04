#!/bin/zsh
# Generate the Xcode project and build Meety.app into macos/build.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Meety.xcodeproj -scheme Meety -configuration "${CONFIG:-Debug}" \
  -derivedDataPath build.noindex/DerivedData -destination 'platform=macOS,arch=arm64' -quiet build
echo "built: $PWD/build.noindex/DerivedData/Build/Products/${CONFIG:-Debug}/Meety.app"
