# Plugin P2 acceptance

2026-10-29. Unpublished source on `main`, not a dev branch or a new public application release. “Linvell Dev” is the existing local debug bundle’s display name. The installed application was not replaced.

## Implemented

- Additive protocol 1 SDK types and `documents/event` request/acknowledgement. Existing P1 command-only packages still work. Event packages declare read permission and negotiate `documentEvents` support.
- Explicitly loaded plugins receive current-document open replay, then open/change/save/close events. Editor transactions and undo/redo feed changes; successful manual and automatic saves feed save events. Consecutive pending changes for the same document are coalesced. Queue bounded to 256 events; commands and events execute serially off the UI thread, with one pending command per plugin. Stop interrupts requests and clears queued events.
- UTF-16 range edits with explicit source revision, overlap/duplicate/Unicode/bounds validation, up to 1,000 ranges, 2 MiB limits, originating pane/document checks, IME protection and one native undo transaction. Whole-document replacement remains supported.
- Native Plugins menu grouped by plugin name, optional per-command shortcuts, conflict rejection, current-window routing and contribution cleanup. Shortcut grammar: cmd/ctrl/option/shift plus one ASCII letter/digit; cmd or ctrl required. Keybindings require the Plugins menu target. Existing native app menu keys, common editor keys and the cmd-K prefix are reserved.
- Configuration merge by top-level key: manifest defaults → per-plugin user JSONC → current workspace `.linvell/settings.json` under `plugins[pluginID]`. Native menu entries create/open the respective configuration files. Project initialization preserves comments and unrelated fields through the existing digest-checked settings writer, including the SSH transport.
- Optional `storage` permission exposes only this plugin’s global/workspace state. State patches merge under a process and file lock, then atomically replace each state file. Per-plugin IDs are digested to isolate case differences on macOS filesystems; workspace identity includes local project path or SSH host alias and root. Missing values delete keys, explicit JSON null persists null. No workspace means no workspace-state writes. Corrupt files, unsupported scopes, oversized payloads and symlinks are rejected without a reset.
- Example version 0.2.0 demonstrates events, configured greetings, persistent invocation counts, range edits, menu entries and Command-Control-9.

## Evidence

- Complete local suite: 205 tests executed, 190 passed, 15 environment/opt-in cases skipped, zero failures (UI 78 / 4 skipped; Core 127 / 11 skipped). This run includes the pre-existing uncommitted performance work.
- Final focused plugin suite: 15 tests passed, zero failures. Following the final pending-command guard, all 7 host tests passed again. Coverage includes event lifecycle ordering/coalescing, P1 compatibility, range/Unicode/version rejection and undo, menu conflicts and unload cleanup, JSONC preservation and stale-write rejection, configuration precedence, state namespaces, concurrent unrelated-key writers, corrupt/oversized state, null versus deletion, crash/timeout and stop.
- A new menu-title assertion initially depended on XCTest acquiring a key window; the fixture was corrected to pass its explicit workspace when rendering its menu. The final assertion and real menu verification passed.
- SwiftPM example and the local debug application built. A separate temporary QA bundle exercised the actual native UI, preserving the existing app’s windows and installation.
- Actual UI: loaded the sample, ran its Command-Control-9 range edit on Chinese/emoji text, undid it, edited/saved user configuration through its menu, and observed the configured greeting. Opened workspace configuration through its menu, saved a commented override, and observed the workspace prefix take precedence.
- Actual UI event status reported `save @ revision 3`, then `close @ revision 3` after closing the scratch file. Restarting the QA app and reloading the package preserved the workspace greeting and invocation count (`#1` → `#2`). The final Plugins menu showed the correct plugin title, and stopping removed its dynamic submenu. The QA application was then closed.
- Bilingual website guide includes the new protocol/SDK fields, buildable example, events, ranges, menus/shortcuts, configuration paths and precedence, state semantics, and remaining limitations. Chinese/English content and navigation were checked in the browser; the 3 existing website metadata tests passed.

## Limits

- This remains trusted local native-code execution, not an OS sandbox. No secret storage, marketplace, VSIX compatibility, remote plugin execution or new app release is included.
- Plugin menu contributions currently target only the native Plugins submenu. Context menus, arbitrary built-in menu placement, chords/function keys and global-shortcut conflict discovery remain outside P2.
- Events are coalesced snapshots rather than a lossless edit log. Closing a window or quitting stops processes without promising final close delivery. Oversized text, older-revision saves and close events carry metadata only.
- State writes are atomic per file, not jointly atomic with another namespace or editor edits. Same-key concurrent updates are last-write-wins; there is no atomic increment API. A state patch may commit before a stale UI result is rejected or while stop begins. Workspace state is kept locally even for SSH projects; aliases to the same SSH host intentionally define distinct identities.
- Configuration uses saved files, not unsaved editor buffers. Local overrides are shallow; no configuration schema/settings form or configuration-change event is provided. SSH configuration reuses the existing transport but was not revalidated against a live SSH device in this P2 run. Intel runtime and physical frame cadence remain untested.
