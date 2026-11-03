#!/bin/zsh
# Release build of Meety.app, signed with hardened runtime, into macos/build/Meety.app.
#   SIGN_IDENTITY  codesigning identity (default: the first Developer ID Application, else Apple Development)
#   NOTARY_PROFILE notarytool keychain profile; when set, the app is notarized and stapled
#   INSTALL=1      also copy the app to /Applications/Meety.app
set -euo pipefail
cd "$(dirname "$0")/.."

identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
identity=${identity:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}
[[ -n $identity ]] || { echo "No codesigning identity found; set SIGN_IDENTITY." >&2; exit 1 }
team=${identity##*\(}; team=${team%\)}
echo "signing as: $identity"

xcodegen generate --quiet
xcodebuild -project Meety.xcodeproj -scheme Meety -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp build

app=build/Meety.app
rm -rf $app
ditto build/DerivedData/Build/Products/Release/Meety.app $app
codesign --verify --deep --strict $app # embedded frameworks must share the app's team for library validation

if [[ -n ${NOTARY_PROFILE:-} ]]; then
  ditto -c -k --keepParent $app build/Meety.zip
  xcrun notarytool submit build/Meety.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple $app
  rm build/Meety.zip
fi
spctl -a -vv $app || echo "Gatekeeper rejects it until it is notarized (set NOTARY_PROFILE)."

if [[ ${INSTALL:-} == 1 ]]; then
  rm -rf /Applications/Meety.app
  ditto $app /Applications/Meety.app
  echo "installed: /Applications/Meety.app"
fi
echo "packaged: $PWD/$app"
