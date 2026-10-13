#!/usr/bin/env bash
set -euo pipefail
: "${RELEASE_VERSION:?Set RELEASE_VERSION}"
python3 scripts/release/metadata.py validate "$RELEASE_VERSION"
xcodebuild -project alt-tab-macos.xcodeproj -scheme Release -configuration Release \
  -derivedDataPath DerivedData "CURRENT_PROJECT_VERSION=$RELEASE_VERSION" \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  'CODE_SIGN_IDENTITY=Developer ID Application: Richard Borcsik (S64PDPJKMJ)' \
  DEVELOPMENT_TEAM=S64PDPJKMJ CODE_SIGN_STYLE=Manual | scripts/xcbeautify
lipo "${XCODE_BUILD_PATH:-DerivedData/Build/Products/Release}/Switcheroo.app/Contents/MacOS/Switcheroo" -verify_arch arm64 x86_64
