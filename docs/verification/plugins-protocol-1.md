# Plugin protocol 1 — development acceptance

2026-10-29. Source development preview; no new public app release or installed application replacement.

## Implemented

- Public `LinvellPluginKit` SwiftPM library; `Examples/HelloPlugin` standalone executable package.
- Explicit directory loading through Edit or the command palette, package validation and trust notice; per-window sessions, no project discovery or automatic startup restoration.
- Lazy independent process, Content-Length framed JSON-RPC, protocol 1 handshake, declared command dispatch, per-plugin serialization and 10-second request timeout.
- Optional document snapshots and whole-document replacements, read/write permission checks, 2 MiB text limits, origin/revision/text/IME validation and native undo.
- Stop from Edit or the command palette; same-ID loading replaces the old session. Stop interrupts pending calls, terminates the process and uses a one-second force-termination fallback. Window close stops its plugins.

## Verification

- `swift test --scratch-path ~/dev/build/linvell/swiftpm --filter 'PluginHostTests|PluginEditingTests'`: 6 tests passed, no failures. Covers Unicode, repeated commands, undeclared commands, editor permissions, protocol rejection, executable traversal/symlink escapes, crash, timeout, explicit restart, cancellation via stop, undo and stale results.
- Complete local suite: 196 tests executed, 181 passed, 15 opt-in/environment-dependent cases skipped, zero failures. Includes pre-existing uncommitted interaction-performance work. Core: 120 / 11 skipped. UI: 76 / 4 skipped.
- `bash script/build_and_run.sh --build-only`: development app built and ad-hoc signed; not a Developer ID release/publication.
- Compiled SDK example exercised over actual stdin/stdout: handshake, greeting, Chinese/emoji transformation and clean EOF passed.
- Actual development UI: selected built package, reviewed trust notice, loaded it, found both example commands, ran greeting, transformed a fresh scratch document containing Chinese/emoji, undid with Command-Z and stopped plugins. The scratch tab was discarded; existing user tabs were preserved.
- Website quick-start build block extracted and executed in Bash (app launch omitted because the development app had already been verified). Example executable and manifest produced successfully under `~/dev/build`.
- Website Chinese/English content, navigation and code examples checked in a browser; website release metadata tests passed (3 tests).

## Remaining scope at P1

Document events, range edits, native plugin menus/shortcuts and configuration/state have since been added by [P2](plugins-p2.md). The list below records the original P1 boundary.

### Original boundary

This preview does not enforce an OS security sandbox. Manifest permissions restrict host API data and edits, not a program’s direct file/network/process access. Only trusted local development programs should be loaded. Processes execute on the Mac, even when transforming a remote editor buffer.

Document events, range edits, arbitrary native menu/shortcut contributions, persistent configuration/storage, declarative views and resource contributions, language/task/debug providers, remote plugin hosting, packaging/signing/distribution, per-request cancellation and resource accounting remain open. No VSIX, Nova or Vim extension compatibility or marketplace is provided. Intel runtime and remote plugin execution were not tested; only the current Mac development build was exercised. No sustained display frame-rate claim is made.
