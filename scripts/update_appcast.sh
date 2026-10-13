#!/usr/bin/env bash
set -euo pipefail
: "${RELEASE_VERSION:?Set RELEASE_VERSION}"
: "${SPARKLE_ED_PRIVATE_KEY:?Set SPARKLE_ED_PRIVATE_KEY}"
release_dir="${RELEASE_DIR:-build/release}"
archive="$release_dir/Switcheroo-$RELEASE_VERSION.zip"
signature="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | vendor/Sparkle/bin/sign_update --ed-key-file - -p "$archive")"
public_key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "${XCODE_BUILD_PATH:-DerivedData/Build/Products/Release}/Switcheroo.app/Contents/Info.plist")"
swift scripts/release/VerifyUpdate.swift "$archive" "$signature" "$public_key"
previous_feed=browser-tabs-appcast.xml
releases="$(gh api 'repos/richard-better/switcheroo/releases?per_page=100')"
has_release="$(printf '%s' "$releases" | python3 -c 'import json,sys; print(any(not r["draft"] and not r["prerelease"] for r in json.load(sys.stdin)))')"
if [[ "$has_release" == True ]]; then
  latest_tag="$(gh release view --repo richard-better/switcheroo --json tagName --jq .tagName)"
  mkdir -p "$release_dir/previous"
  gh release download "$latest_tag" --repo richard-better/switcheroo --pattern appcast.xml --dir "$release_dir/previous" --clobber
  previous_feed="$release_dir/previous/appcast.xml"
fi
python3 scripts/release/metadata.py generate "$RELEASE_VERSION" "$archive" "$signature" --previous-feed "$previous_feed"
