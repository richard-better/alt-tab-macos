# Ship a signed Switcheroo release

## Configure credentials

Use Apple Developer team `S64PDPJKMJ` throughout this procedure. Keep the bundle ID `me.richardb.window-switcher`.

1. Create a [Developer ID Application certificate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) in Apple Developer. Generate the private key and CSR locally, upload the CSR, and download the certificate. Export the certificate with its private key as a password-protected `.p12`.
2. Set `APPLE_P12_CERTIFICATE` to the base64-encoded `.p12` and `APPLE_P12_PASSWORD` to its password in [Switcheroo's GitHub Secrets](https://github.com/richard-better/switcheroo/settings/secrets/actions). Pass secret values through stdin to `gh secret set`; do not put them in command arguments or shell history.
3. Create an App Store Connect team API key with the Developer role for notarization. Set `APPLE_API_PRIVATE_KEY` to the downloaded `.p8` contents, `APPLE_API_KEY_ID` to its ID, and `APPLE_API_ISSUER` to its issuer UUID. [Apple's authentication instructions](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool) describe these fields.
4. Generate a [Sparkle signing key](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures) using `generate_keys --account me.richardb.window-switcher` from the Sparkle distribution. Export it with `-x` and set `SPARKLE_ED_PRIVATE_KEY` through stdin. Embed the matching public key in `Info.plist` as `SUPublicEDKey` before building.
5. Keep a secure backup of the signing keys and the `.p12` password. This checkout's initial credentials live outside Git in `~/.local/share/switcheroo/signing`; Sparkle also stores its key in the login Keychain.

The workflow creates a temporary keychain on the macOS runner. It does not need an App Store app record or an installer signing certificate for ZIP distribution.

## Build a candidate

Choose a version at least as high as `CURRENT_PROJECT_VERSION` in `config/base.xcconfig` and greater than every version already released.

Add a `## <version>` entry to `changelog.md` before building. Describe Switcheroo's changes and include an Upstream section with the incorporated AltTab release and commit. The workflow uses this entry as the GitHub release notes. Preserve these details when incorporating future upstream updates.

```sh
gh workflow run release.yml --repo richard-better/switcheroo --ref richard-patches -f version=1.0.1 -f publish=false
```

Download the workflow artifact after the job succeeds. Install the extracted `Switcheroo.app` in `/Applications`, check browser-tab and window switching, and grant the requested macOS permissions. Verify an upgrade from the prior release before publishing subsequent versions.

To run the scripts locally, install your Developer ID identity in the login Keychain and store notarization credentials with `xcrun notarytool store-credentials`. Run these commands from the repository root:

```sh
export RELEASE_VERSION=1.0.1
export NOTARY_KEYCHAIN_PROFILE=switcheroo-notary
scripts/build_app.sh
scripts/package_and_notarize_release.sh
export SPARKLE_ED_PRIVATE_KEY="$(cat ~/.local/share/switcheroo/signing/sparkle.key)"
scripts/update_appcast.sh
unset SPARKLE_ED_PRIVATE_KEY
```

The scripts write the ZIP, notarization result, appcast, checksum, release notes, and Homebrew cask to `build/release`. Sign in with `gh auth login` before running `update_appcast.sh`; it downloads the published appcast and preserves its history.

## Publish the release

To publish from GitHub, open the [Switcheroo release workflow](https://github.com/richard-better/switcheroo/actions/workflows/release.yml) and select **Run workflow**. Choose the `richard-patches` branch, enter the release version, and enable **Publish to GitHub Releases after verification**.

Run the workflow with `publish=true` after verifying the candidate. Alternatively, push a `switcheroo-v<version>` tag to trigger publication. A workflow run with `publish=true` builds and notarizes the selected commit again.

```sh
gh workflow run release.yml --repo richard-better/switcheroo --ref richard-patches -f version=1.0.1 -f publish=true
```

The release appears at `https://github.com/richard-better/switcheroo/releases`. Its `appcast.xml` asset supplies automatic updates. Publication does not change the development version in `config/base.xcconfig`.

## Update the Homebrew tap

After publishing, run the tap's update workflow:

```sh
gh workflow run update.yml --repo richard-better/homebrew-tap
```

The tap imports the cask from the latest published release. It needs no signing keys or access to Switcheroo's secrets. Users can then install with `brew install --cask richard-better/tap/switcheroo`.
