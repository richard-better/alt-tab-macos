# Signed Switcheroo releases

## Distribution identity

Release builds use `Developer ID Application: Richard Borcsik (S64PDPJKMJ)`, Team ID `S64PDPJKMJ`, and bundle ID `me.richardb.window-switcher`. These values stay stable across releases because permission grants and license Keychain access depend on the app's identity.

Before notarization, `codesign --test-requirement` verifies the Apple trust anchor, Developer ID Application certificate type, Team ID, and signing identifier. Human-readable certificate names are diagnostic output. [Apple's code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) define the certificate OIDs used by this check.

The build signs Sparkle's nested helpers, then its framework, then Switcheroo. Release signatures use hardened runtime and secure timestamps. Debug builds retain their development signing behavior.

## Release trigger

The `Switcheroo release` workflow accepts a numeric `major.minor.patch` version through `workflow_dispatch`. It produces a candidate artifact by default. Setting `publish=true` publishes a release after every verification step passes. Pushing `switcheroo-v<version>` also publishes that version. Ordinary branch pushes do not publish releases.

Switcheroo's version history starts at `1.0.0`, independently of AltTab's versions. Both app version fields use the Switcheroo release version. Versions match or exceed `CURRENT_PROJECT_VERSION` and exceed every version in the previously published appcast. A tag that already points to another commit cannot identify a release. Existing releases are not overwritten by retries.

## Verification and publication

The workflow runs app tests and release-tooling tests before building a universal app. Both `arm64` and `x86_64` slices must be present.

Notarization must return `Accepted`. Rejections retain the submission log and stop publication. A timeout or authentication failure stops publication. The app's ticket is stapled and validated, and its signature and Gatekeeper assessment must pass before the app is packaged again.

Sparkle signs the final ZIP. `VerifyUpdate.swift` checks that signature against the built app's `SUPublicEDKey`, so an unrelated private key cannot publish an unusable update.

The ZIP's final bytes determine the appcast length, SHA-256 checksum, and Homebrew cask checksum. The appcast preserves older releases for users whose macOS version cannot run the latest build. All download and release-note URLs belong to `richard-better/switcheroo`.

The workflow uploads candidate artifacts before publication. Publication creates a draft release with the ZIP, appcast, checksum, and cask, then publishes it. The app checks `https://github.com/richard-better/switcheroo/releases/latest/download/appcast.xml`.

## Credential handling

The production environment uses `APPLE_P12_CERTIFICATE`, `APPLE_P12_PASSWORD`, `APPLE_API_PRIVATE_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`, and `SPARKLE_ED_PRIVATE_KEY`. Secrets are scoped to the steps that need them. Shell tracing stays disabled. The runner imports the certificate into a temporary keychain and deletes the keychain and temporary credentials even when the job fails.

For local notarization, `NOTARY_KEYCHAIN_PROFILE` selects credentials already stored by `notarytool`. Private keys are never committed.

## Checks

Run `python3 scripts/release/ReleaseTests.py` for version validation, archive metadata, fork URLs, checksum consistency, and preservation of older releases. The workflow runs the same tests. Run `bash ai/test.sh` for app tests.
