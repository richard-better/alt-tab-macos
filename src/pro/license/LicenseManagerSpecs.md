# LicenseManager specs

## Feature access

`LicenseManager` supplies the state used by feature gates, preference reads, and upgrade prompts.
Normal builds always use `.pro`. No license key, trial, validation result, or version cutoff is required.

- All features are available before initialization.
- `initialize()` restores preferences remembered when features were locked, then notifies state observers with `.pro`.
- `refreshState()` keeps `.pro` and does not notify observers when the state is unchanged.
- Initialization and refresh do not read the Keychain, contact the license server, or change license defaults.
- New installations do not start a trial. Existing trial dates and stored licenses remain intact.
- License validation requests and version cutoff checks are absent.
- Deactivation removes stored license information and keeps all features available.

The existing `.pro` state suppresses trial prompts and preference downgrades through the shared feature gates.

## Optional license management

Explicit activation and deactivation remain available for managing existing licenses. Their success or failure does not restrict feature access.

Activation stores the key, instance, optional variant, and customer email. Failed writes remove only accounts written by that activation.
A failed Keychain write preserves the previous value of that account. Errors reach the caller without locking features.
Deactivating another machine's instance leaves local license storage untouched.

The Keychain service, app bundle identifier, and signing configuration remain unchanged.

## Debug QA states

`mockProUser()` and `mockTrialDay()` exist only in Debug builds. They provide in-memory states for exercising UI behavior.
Refresh preserves these overlays. They do not read, clear, or write real license storage.
Trial-day calculations remain available for these tools and existing trial metadata.

## Verification

`LicenseManagerTests.swift` uses an isolated defaults suite with a mock clock, Keychain, and API.
The tests cover fresh installs, relaunches, expired trials, invalid or unvalidated stored licenses, and stale validation timestamps.
They verify unrestricted access, no automatic server calls or Keychain reads, and unchanged stored data.
Callback tests verify that preference restoration precedes state notifications on initialization and activation.
Activation and deactivation tests cover successful requests, API errors, seat limits, failed writes, and local storage preservation.
Debug tests verify that simulated states survive refresh without changing stored licenses.
