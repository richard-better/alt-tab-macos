#!/usr/bin/env bash
set -euo pipefail
: "${APPLE_P12_CERTIFICATE:?Set APPLE_P12_CERTIFICATE}"
: "${APPLE_P12_PASSWORD:?Set APPLE_P12_PASSWORD}"
: "${RUNNER_TEMP:?Run on a GitHub Actions runner}"
: "${GITHUB_ENV:?Run on a GitHub Actions runner}"
umask 077
signing_dir="$RUNNER_TEMP/switcheroo-signing"
mkdir -p "$signing_dir"
keychain="$signing_dir/release.keychain-db"
keychain_password="$(openssl rand -hex 32)"
printf '%s' "$APPLE_P12_CERTIFICATE" | base64 --decode > "$signing_dir/certificate.p12"
security create-keychain -p "$keychain_password" "$keychain"
printf 'RELEASE_KEYCHAIN=%s\n' "$keychain" >> "$GITHUB_ENV"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -P "$APPLE_P12_PASSWORD" -k "$keychain" -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
security find-identity -v -p codesigning "$keychain" | grep -F 'Developer ID Application: Richard Borcsik (S64PDPJKMJ)'
rm "$signing_dir/certificate.p12"
