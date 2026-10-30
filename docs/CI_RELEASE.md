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

## Homebrew distribution

Install using the Linvell-maintained tap:

```sh
brew install --cask huluxiaohuowa/tap/linvell
brew upgrade --cask --greedy huluxiaohuowa/tap/linvell
```

The Homebrew step runs after the stable GitHub Release and its distribution artifacts have been published. `script/publish_homebrew.py` downloads the published Universal ZIP and `SHA256SUMS.txt`, checks the complete archive, and generates the Cask. It rejects drafts, prereleases, missing or duplicate checksums, archive mismatches and version downgrades. Repeating the same release is safe. The workflow checks Ruby style and pushes the Cask to `huluxiaohuowa/homebrew-tap`.

`HOMEBREW_TAP_SSH_KEY` is a deploy key with write access only to that tap. It is independent of Apple credentials and the developer's personal GitHub login. The workflow materializes it temporarily under the protected build directory and removes it on exit. A failed Homebrew step leaves the already published GitHub Release available; rerun the Homebrew job or manually run `Publish Homebrew` with the existing stable tag to retry without bumping the application version.

The app requires macOS **15.6**; Homebrew Casks express this as the Sequoia major release. Universal archives contain arm64 and x86_64 binaries. Normal uninstall keeps documents and application data; Homebrew's explicit `--zap` also removes the listed Linvell data directories.

### Official Homebrew Cask submission

The same generated `Casks/linvell.rb` can be submitted as `Casks/l/linvell.rb` in `Homebrew/homebrew-cask`; a third-party tap does not imply official inclusion. Before initial submission, run `brew style`, `brew audit --cask --online`, `brew audit --cask --new`, and an installation/uninstallation check. The default GitHub release URL supplies Homebrew livecheck.

As checked on 2026-10-30, the repository is younger than 30 days and below Homebrew's normal self-submission notability thresholds. Official inclusion is pending eligibility or an explicitly justified maintainer exception, not an automated guarantee. See [package acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy) and [acceptable casks](https://docs.brew.sh/Acceptable-Casks).

Homebrew also requires the human contributor to review AI-assisted content before requesting review, disclose assistance in the PR, and personally answer maintainer questions. The initial submission must therefore follow the author's review. See [responsible AI usage](https://docs.brew.sh/Responsible-AI-Usage). Once accepted, official Homebrew updates remain subject to its review and autobump processes; the Linvell tap continues updating independently after every stable release.
