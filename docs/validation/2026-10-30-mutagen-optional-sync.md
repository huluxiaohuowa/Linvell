# Optional Mutagen synchronization acceptance — 2026-10-30

## Implemented behavior

- Mutagen is an optional executable discovered in the CLI environment. The missing-dependency UI offers exactly `brew install mutagen-io/mutagen/mutagen`; executable discovery shows a green capability indicator, separately from synchronization health. Linvell neither bundles nor installs Mutagen.
- SSH projects using a local agent get a private replica and isolated Mutagen data directory. Initial synchronization completes before a new local CLI starts. Sessions use `two-way-safe`, ignore VCS metadata, and reject mismatched host/project endpoints or unsafe synchronization modes.
- Opening a project, selecting an execution location, inspecting history and installation discovery start no synchronization daemon. An explicit connection check performs bounded synchronization, then stops if no local runtime needs it. Multiple local sessions share synchronization; the last one stopping flushes with a timeout, pauses the session and stops/reaps the owned supervisor and daemon. Other workspaces retain their own references. No login item is registered; replicas and synchronization state remain for recovery.
- Clean remote editor buffers refresh after synchronized writes. Dirty buffers retain their text, report external changes and suspend automatic saving. The existing digest-checked remote save rejects stale writes. Conflicts preserve both versions; the review action opens the local replica and remote version in the current workspace without modifying either. Explicitly saving the reviewed merge to both versions clears synchronization conflicts. This is file synchronization and manual review, not collaborative character-level editing or automatic three-way merging.
- Local CLI shell commands remain local; remote builds/tests require explicit SSH execution.

## Verified evidence

- Real Mutagen 0.18.1 against a disposable Linux SSH project: initial copy, local-to-remote writes, remote-to-local writes, rename, delete, isolated project identity, suspend/resume, multiple clients, conflicting edits preserved, reviewed merge resolution and idle shutdown.
- Native view/PTY acceptance: opening an SSH project and detecting installation create no daemon state; green capability text; two concurrently running local fixture CLIs; stopping one retains synchronization for the other; stopping the last flushes its final file and removes the supervisor/daemon; a subsequent conflicting connection exposes review and starts no new CLI or lingering daemon.
- Real remote editor acceptance: an agent replica edit refreshes clean editor storage; a manual remote save arrives in the replica; later concurrent changes preserve unsaved manual text, flag the conflict, suppress scheduling auto-save and reject a stale remote save.
- Full regression before the final conflict-review UI addition: 110 native tests (3 skipped), 176 core tests (15 skipped), no failures. After the final changes, the affected Agent suites were rerun with real Mutagen/SSH fixtures and passed; the installed Codex metadata acceptance remained opt-in. Fourteen release-script checks passed. Release CI reruns the default complete suites.
- An initial broad run found an outdated SSH fixture manifest pointing to a different local directory without the running-agent fixture. The current fixture and manifest were synchronized and the same tests passed on rerun. A separate initial Mutagen harness used a path exceeding Darwin’s Unix-socket limit; shortening that test-only state path exposed the actual SSH path, which then passed. Neither failure was skipped or counted as passing.

## Limits

No new model API calls or five-provider authentication/context-restoration acceptance is claimed. Physical display cadence, isolated Homebrew installation, signed upgrade integration and other opt-in toolchain/network cases were not enabled in this local full run. Remote Git mutation remains excluded, and no remote Git command ran. Source and fixtures were rsynced before remote runs. No standalone Linvell QA application was launched. Existing AppKit constraint warnings are still emitted by native test hosts.

Publication, signing, notarization and downstream tap synchronization are verified separately after release CI finishes.
