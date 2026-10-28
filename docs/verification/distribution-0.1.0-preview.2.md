# Preview 2 verification — 2026-10-28

Source: `8fdc6fec66c4ba0ab0b74e25143b1544b1f0567e`.

## Build and distribution

- Local Universal release build, arm64 and x86_64, minimum macOS 15.6.
- 35 tests passed: 28 core and 7 native AppKit integration tests, including immediate Vim caret synchronization on selection changes, multi-cursor input/undo, Unicode deletion and resized long-line wrapping.
- Developer ID signing with Hardened Runtime, Apple notarization Accepted, stapling and Gatekeeper assessment passed.
- Published [v0.1.0-preview.2](https://github.com/huluxiaohuowa/Linvell/releases/tag/v0.1.0-preview.2) with ZIP, DMG, SHA256SUMS.txt and release-manifest.json.

## Native observations

- Python and Markdown icons render in the tree; Python renders in tabs and quick-open results.
- Three occurrences were replaced together, subsequent input reached all three carets, and undo removed one input transaction.
- Normal-mode selection moved from line 1 to line 8 without Escape; the old block disappeared and the new block matched the selection. Physical mouse targeting still needs an independent recheck because the UI automation's coordinate clicks did not move the selection reliably.
- Update settings show four independent switches and complete descriptive text. The real GitHub API reported preview 2 available to a locally signed preview-1-version baseline.
- Current fish shell started normally; after startup, ANSI red/green/blue output and the prompt rendered in the terminal panel. PTY size was 14 rows by 101 columns. Full TUI and shell lifecycle coverage remains open.

## Signed installer integration

The production helper installed the notarized candidate over a disposable, separately signed baseline. It waited for the test parent to exit, atomically swapped the app, retained preview 1, and produced preview 2 with valid signature, Gatekeeper acceptance and notarization staple. No user-installed application was replaced for this test.

Real GitHub download, checksum/signature verification and Install & Restart passed against a disposable signed baseline; the helper retained the previous version. The user-installed application was not replaced.

## Large-file measurements

Release build on this Mac, generated UTF-8 Swift text with ordinary line lengths:

| Size | Lines | First layout | Jump to midpoint |
| --- | ---: | ---: | ---: |
| 1 MiB | 13,798 | 0.052 s | 0.008 s |
| 10 MiB | 137,971 | 0.070 s | 0.054 s |
| 100 MiB | 1,379,706 | 0.430 s | 0.520 s |

These native timings include background decode and initial layout; they are not frame-latency, peak-memory or same-workload Sublime comparisons. The active screen reported 60 Hz, so 120 Hz acceptance is not established. Large minified files and editing latency remain open.

## Remaining acceptance

Physical Finder cross-application drag, complete Vim, IME/multi-cursor composition, Intel runtime, clean-machine first launch, two-Mac iCloud propagation/concurrency and full IDE behavior are not established by this preview.
