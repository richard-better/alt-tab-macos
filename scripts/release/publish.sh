#!/usr/bin/env bash
set -euo pipefail
: "${RELEASE_VERSION:?Set RELEASE_VERSION}"
: "${GITHUB_SHA:?Run on a GitHub Actions runner}"
release_dir="${RELEASE_DIR:-build/release}"
tag="switcheroo-v$RELEASE_VERSION"
if git rev-parse --verify "refs/tags/$tag" > /dev/null 2>&1; then
  [[ "$(git rev-list -n 1 "$tag")" == "$GITHUB_SHA" ]] || { echo 'Release tag points to a different commit' >&2; exit 1; }
fi
gh release create "$tag" --repo richard-better/switcheroo --target "$GITHUB_SHA" \
  --draft --title "Switcheroo $RELEASE_VERSION" --notes-file "$release_dir/release-notes.md" \
  "$release_dir/Switcheroo-$RELEASE_VERSION.zip" "$release_dir/appcast.xml" \
  "$release_dir/SHA256SUMS" "$release_dir/switcheroo.rb"
gh release edit "$tag" --repo richard-better/switcheroo --draft=false --latest
