# GitHub Actions releases

The `Release macOS` workflow runs on the standard `macos-15-intel` GitHub-hosted image. It builds both arm64 and x86_64 and verifies the Universal app, signs the app/helper with Developer ID, submits to Apple notarization, staples the result, checks Gatekeeper and creates DMG/ZIP/checksum/manifest assets in GitHub Releases. Standard hosted runners are free for public repositories; large runners are not used.

## Start a release

`gh workflow run release.yml --field bump=patch` defaults to one patch increment. Choose `minor` or `major` explicitly. The workflow commits the resulting application version before building. A stable `vX.Y.Z` tag can instead build a version already committed in `Resources/Info.plist`; matching committed release notes are required for tag releases.

Version components use a carry threshold of **1000** for patch and minor; major has no fixed ceiling. For example, patch updates go `0.2.9 → 0.2.10`, `0.2.999 → 0.3.0`, and `0.999.999 → 1.0.0`. An explicit minor update clears patch (`0.2.123 → 0.3.0`), and an explicit major update clears both lower components (`0.2.123 → 1.0.0`). `CFBundleVersion` remains an independent integer build counter.

Local `python3 script/update_version.py` remains patch-by-default. Local production packaging is optional for explicit diagnostics; normal distribution runs in CI.

## Credentials

The Actions Secret `APPLE_RELEASE_CONFIG` contains only `common.teamId`, `common.certificates.developerIdApplication` and `common.appStoreConnect` fields needed for Developer ID signing and notarization. It excludes other applications, App Store distribution certificates and provisioning profiles. CI generates its own temporary keychain password.

`script/materialize_ci_apple.py` creates a mode-0600 file outside the checkout. Credentials are scoped to the materialization step and protected file; the signing keychain is temporary. Cleanup runs even after failure. Credentials, protected signing logs and keychains are never release/upload artifacts. Only trusted main/tag workflows can access the secret; there is no pull-request release trigger.

## Verification boundaries

The runner executes native/core tests available without personal SSH configuration. Disposable SSH and physical display-cadence acceptance are local opt-in tests, recorded separately; they are not silently counted as CI passes. The release manifest records GitHub Actions as the build origin and links its run ID. A successful workflow must produce a signed, notarized public download before the release is considered complete.
