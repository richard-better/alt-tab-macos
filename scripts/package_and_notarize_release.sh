#!/usr/bin/env bash
set -euo pipefail
: "${RELEASE_VERSION:?Set RELEASE_VERSION}"
python3 scripts/release/metadata.py validate "$RELEASE_VERSION"
release_dir="${RELEASE_DIR:-build/release}"
app="${XCODE_BUILD_PATH:-DerivedData/Build/Products/Release}/Switcheroo.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")" == "$RELEASE_VERSION" ]] || { echo 'Built app version does not match RELEASE_VERSION' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == me.richardb.window-switcher ]] || { echo 'Unexpected app bundle ID' >&2; exit 1; }
identity="$(codesign -dv "$app" 2>&1)"
printf '%s\n' "$identity" | grep -Fx 'TeamIdentifier=S64PDPJKMJ'
printf '%s\n' "$identity" | grep -Fx 'Authority=Developer ID Application: Richard Borcsik (S64PDPJKMJ)'
mkdir -p "$release_dir"
archive="$release_dir/Switcheroo-$RELEASE_VERSION.zip"
codesign --verify --deep --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$archive"
notary_args=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
  : "${APPLE_API_PRIVATE_KEY:?Set APPLE_API_PRIVATE_KEY or NOTARY_KEYCHAIN_PROFILE}"
  : "${APPLE_API_KEY_ID:?Set APPLE_API_KEY_ID}"
  : "${APPLE_API_ISSUER:?Set APPLE_API_ISSUER}"
  umask 077
  notary_key="$(mktemp)"
  trap 'rm -f "$notary_key"' EXIT
  printf '%s' "$APPLE_API_PRIVATE_KEY" > "$notary_key"
  notary_args=(--key "$notary_key" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
fi
result="$release_dir/notarization.json"
submit_status=0
xcrun notarytool submit "$archive" "${notary_args[@]}" --wait --timeout 30m --output-format json > "$result" || submit_status=$?
if [[ "$submit_status" != 0 ]]; then cat "$result"; fi
status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$result")"
if [[ "$status" != Accepted ]]; then
  submission="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$result")"
  xcrun notarytool log "$submission" "${notary_args[@]}" "$release_dir/notarization-log.json"
  cat "$release_dir/notarization-log.json"
  exit 1
fi
[[ "$submit_status" == 0 ]] || exit "$submit_status"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$archive"
