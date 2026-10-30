# Swift practical patterns regression — 2026-10-30

Scope: the committed main branch plus targeted syntax-analysis sharing, remote-cache accounting and SSH startup corrections. Existing uncommitted Agent and editor work was preserved in its original worktree and is not part of this release.

## Implementation checks

- Shared pending syntax work is published before dispatch. Repeated requests for one revision retain the same ticket; a newer revision cancels the previous ticket. A regression test checks 100 repeated requests, replacement and successful publication.
- Directory-cache capacity accounting stays inside its existing condition lock. Tests cover canonical aliases, repeated replacement, invalidation, entry limits and oversized responses.
- SSH task/terminal wrappers use a non-login POSIX shell for directory setup and run login initialization only in the user's selected shell. Real fish SSH execution, forwarding, preview and stop passed.

## Local verification

- CPU microbenchmark using the actual baseline and updated cache implementations: five runs of 100,000 forced refreshes across 128 directories with 100 entries each, optimized Swift build. Median elapsed time decreased from 28.65 ms to 15.09 ms (about 47%). The harness stubs immutable replies and excludes SSH, parsing and display; this is not an end-to-end application speedup. An earlier remove/reinsert variant regressed this benchmark and was replaced before publication.

- Baseline: 81 native UI tests and 149 core tests, zero failures; 16 environment-dependent skips.
- Final local suite: 88 native UI tests and 158 core tests, zero failures. Three environment-dependent tests skipped pending the signed archive or excluded by the stated boundaries. The full run used a fresh disposable SSH fixture.
- Real clangd and SourceKit definition/rename, plugin clangd and LLDB DAP, Linux SSH plugin transfer/reconnect/process cleanup/Swift SDK, managed language-tool installation and TypeScript indexing were enabled and passed.
- Remote-language acceptance covered persistent requests, 100 cached directory reads, automatic save, external-change protection and syntax folding. Maximum sampled UI timer gap was 94 ms in this fixture; this is not a display frame-rate measurement.
- Python release-script tests: 13 passed. Both release and Homebrew workflow files passed actionlint. Generated Cask passed Ruby style and online audit; isolated application-directory installation succeeded.
- `brew audit --cask --new` is blocked by repository notability. Official Homebrew inclusion is pending; the third-party tap is independently usable.

Remaining local boundaries: physical display-cadence probe skipped; live remote Git mutation test intentionally excluded because remote git commands are prohibited in this environment; signed 0.2.0 → 0.2.3 upgrade is checked separately after the new signed archive exists. Intel hardware and every possible OS/toolchain combination are not covered by local arm64 execution. CI builds the Universal distributable and runs its own tests on Intel.

## Distribution

The `Release macOS` workflow builds, signs, notarizes and publishes the Universal ZIP/DMG. Its downstream `Publish Homebrew` job downloads the published ZIP, verifies the release checksum, checks the Cask style and pushes the new version to `huluxiaohuowa/homebrew-tap`. This job can also be retried independently by stable release tag.

Official Homebrew submission requires human review of the generated Cask and satisfaction of the acceptance policy or a maintainer exception. It is not represented as complete by a successful third-party tap update.

CI initially rejected two existing plugin confirmation expressions with Xcode 26.3 type-check timeouts. The expressions were split without changing their output; the failed 0.2.1 tag is retained and 0.2.2 was cancelled before publication to include installation-aware updates in 0.2.3.

Installation-aware update checks: six source-detection/parser tests and six native updater/settings tests passed, including a real isolated Homebrew installation and a live tap metadata check. Coverage includes a manual copy alongside a brew installation, custom app directories, Caskroom symlinks, official-channel JSON parsing, missing or malformed receipts, unknown taps, the in-app installation guards, and the distinct settings controls. Homebrew's official channel remains fixture-only until inclusion. The Homebrew publication workflow also completed a real CI run against the existing 0.2.0 release.
