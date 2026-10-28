# Linvell 0.1.5 verification — 2026-10-28

## Regressions and measurements

- The selected-child regression failed against the previous directory-only target. Selection and entered-directory cases now resolve to the same folder. Loading clears stale selection and disables opening until the response is current.
- Native routing regression calls the real Git-button action in a remote workspace, loads status/history through an injected repository executor, and asserts no folder picker or sheet opens.
- Repository transport tests verify remote identity and directory survive root resolution, staging preserves literal filenames, and hunk content travels via stdin. The actual generated SSH command is executed against a disposable local Git repository under POSIX and fish shells, including spaces, quotes and shell metacharacters. No Git command was executed on a remote build machine.
- Native scrolling tests assert compatible scroll/clip/document views and unrestricted 60/120/144/240 Hz frame-rate hints. Terminal tests verify the host scheduler owns coalesced display commits.
- A non-key, nearly transparent 8×8 native display probe on the current 120 Hz display measured a median callback interval near 8.33 ms. This is callback cadence, not a pixel-presentation guarantee.
- A 20,000-row remote-folder fixture measured native visible-row materialization/layout separately from networking and presentation; local P95 was below 1 ms.
- Live disposable SSH file-tree/read/write/runner/forward/preview/stop regressions are run separately from the mocked Git transport. Physical remote Git execution remains untested under the workspace's remote-build-machine Git restriction.

Artifacts and detailed local logs remain outside the repository in the build directory. Distribution acceptance is appended after notarization and public-download verification.
