# Linvell 0.2.5 — published (2026-10-30)

[0.2.5](https://github.com/huluxiaohuowa/Linvell/releases/tag/v0.2.5) keeps the left Agents session list/search/resume interface and runs independent concurrent sessions in the main workspace. New Session and provider switching remain available while agents run. Session switching retains PTYs, output and images; Stop only affects the selected session. File links open in the current workspace, macOS inline image rendering is fixed, and actual DSH saved titles are read across concatenated compressed frames. The plugin manager and all previously released editor/plugin changes remain included.

274 local tests: zero failures, two environment-dependent skips. Signed/notarized Universal ZIP and signed 0.2.4 → 0.2.5 upgrade verified; downstream Homebrew publication succeeded with matching version/checksum. [Acceptance and remaining limits](validation/2026-10-30-agent-concurrent-sessions.md). The installed application was not replaced by these checks.

# Existing agent CLIs — 0.2.4 baseline (2026-10-30)

Native selection and session resume for Codex, OpenCode, Pi, Claude Code and DeepSeek Harness, including saved session titles, CLI/desktop shared stores, SSH execution and optional SSHFS mappings for local agents on SSH projects. Open text files and expanded directories update after agent edits while the same CLI process and terminal survive file browsing; dirty buffers retain conflict protection. [Usage, acceptance and limits](AGENT_CLI.md). Included in Linvell 0.2.4, with selection in the left Agents sidebar and execution in the main workspace. Live Codex metadata and local native UI were checked; full provider authentication/context and live SSHFS acceptance remain unverified.

# Plugin P6 — installation and management (source preview)

New on main after 0.2.0: native ZIP/HTTPS/catalog installation, installed/catalog/source tabs, persistent enablement and startup restore, explicit updates, rollback, uninstall and local data cleanup. [Format and limits](plugins/management.md); [acceptance](verification/plugins-management.md). The published 0.2.0 app does not include this manager.

# Plugin P4/P5 — 0.2.0

Implemented manifest LSP language providers, native task terminals, DAP launch controls, bounded logs and SSH workspace plugin runtimes. The SDK is independently buildable on Linux. Validation and limits: [P4/P5](verification/plugins-p4-p5.md). Released as [0.2.0](https://github.com/huluxiaohuowa/Linvell/releases/tag/v0.2.0): Universal Developer ID signed, Apple notarized, stapled and Gatekeeper accepted. The installed application was not replaced.

# Development status

2026-10-29 · 0.1.7 — published

## P3 plugins — unpublished source on main (2026-10-29)

Native AppKit tree/list sidebars, status entries, schema-based settings forms and owned tool windows now accept declarative plugin data. Commands and document event replies can publish validated UI snapshots. Plugins may contribute session themes, PNG/SF Symbol icons with optional file mappings, and explicitly inserted snippets with numbered tab stops. Resource-only packages need no executable. See [P3 acceptance and limits](verification/plugins-p3.md) and the [bilingual SDK guide](https://linvell.fuluwa.top/plugins.html). Automated checks and visible local interaction acceptance passed. These are source changes on `main` without a new public app release; “Linvell Dev” remains only the local debug app label.

## P2 plugins — unpublished source on main (2026-10-29)

Document open/change/save/close events, revision-checked UTF-16 range edits with grouped undo, native Plugins menu/shortcuts with conflict detection, default/user/workspace configuration and persistent plugin/global-workspace state are implemented. The example now demonstrates events, configured greetings, persistent invocation counts and a shortcut-driven prefix edit. See [P2 acceptance](verification/plugins-p2.md) and the [bilingual SDK guide](https://linvell.fuluwa.top/plugins.html). This is source on `main`, not a separate dev branch or a new published app release. The local build’s “Linvell Dev” label only distinguishes the debug app.

## Plugin development preview — source only (2026-10-29)

Protocol 1 now provides explicit per-window local package loading, a Swift `LinvellPluginKit` SDK, a lazily started independent process, command palette contributions and optional revision-checked, undoable current-document replacements. The HelloPlugin example builds and ran through the actual development UI. See [verification and remaining scope](verification/plugins-protocol-1.md) and the [bilingual developer guide](https://linvell.fuluwa.top/plugins.html). This has not been packaged as a new public app release.

## Added in 0.1.7

[0.1.7 is published](https://github.com/huluxiaohuowa/Linvell/releases/tag/v0.1.7). [GitHub Actions](https://github.com/huluxiaohuowa/Linvell/actions/runs/40815230849) built Universal binaries, signed, notarized, stapled and published the release. No installed application was launched or replaced by the agent.

- Native lexical highlighting, bracket matching, language-aware indentation, structural folding and relative line numbers, shared by local and remote documents.
- Optional conflict-checked auto-save for existing local/SSH files; same-size dirty dot and close X, with revision-safe completion and IME composition protection.
- Native definition/reference navigation, back/forward history, hover, completion and diagnostics through a Swift LSP client and installed host toolchains.
- Independent per-language interpreter/compiler/server selection in project-root `.linvell/settings.json`, locally or on SSH hosts. JSONC comments and unrelated settings are preserved; custom language associations are supported. Paths do not enter iCloud preferences.
- Previewed semantic symbol rename across files, stale-edit checks, grouped undo/redo and save-all. Analysis is bounded to 2 MiB per file; rename is bounded to 500 files and 32 MiB of source. File creation/moves/deletion are not part of this rename implementation.
- Native submodule overview and safe add/update/sync/branch/URL/gitlink/remove workflows. Additional native operation forms cover deinit, merge/rebase updates, summary, recursive commands and absorbing Git directories.
- Git operation forms for branches, history changes, conflicts, stash, tags, remotes, reflog and worktrees, plus arbitrary Git argv and a persistent native PTY console for interactive commands. A graphical three-way merge editor is not included.
- Shared SSH transport connections, cached native remote directory views and explicit refresh. No separately downloaded or permanently installed Linvell server is needed.
- ZIP-only pending updates, explicit unregister-before-delete cleanup, one compressed rollback and removal of obsolete generated production bundles. Duplicate Finder handlers on the development Mac were cleaned without replacing its installed app.

Acceptance includes native AppKit tests, actual clangd and SourceKit-LSP semantic tests, real Git/submodule fixtures, actual SSH language/config/save/conflict tests, signed-release update tests, and visible-row CPU layout measurements. Display-link configuration is verified; a physical cadence probe requires an unoccluded display surface and does not prove every presented frame's rate. Bilingual usage instructions are published at https://linvell.fuluwa.top/guide.html, with detailed Markdown sources in `linvell-web/docs/guide-0.1.7.*.md`.

The final local pre-release suite ran 151 tests: 144 passed, 7 opt-in tests skipped, zero failures. The subsequent folded multi-edit regression and complete CI suite passed. The skipped cases require separate remote tree/runner/Git fixtures or an unoccluded physical display; the dedicated SSH language/config/auto-save test ran successfully. Its maximum UI timer gap was about 18 ms. For 20,000 remote-directory rows, visible-row CPU layout measured about 0.22 ms median / 0.27 ms P95. These figures are not presented-frame-rate claims. The isolated signed 0.1.5 → 0.1.6 update retained one compressed rollback and removed temporary application registrations; the installed app remained 0.1.6.

## Implemented foundation

- Native AppKit workspace with activity rail, explorer, file tabs, shared-storage split editors and resizable native panes.
- Explicit file-tree indentation, disclosure controls and hierarchy guides.
- Four built-in light/dark themes, 15 pt default text, font family/size controls and categorized settings.
- Shared language icons in the explorer, file tabs and quick file picker; 21 bundled Devicon assets with native fallback icons for other file types.
- UTF-8 / BOM / UTF-16 text loading, CR/LF/CRLF preservation, atomic file writes, permission preservation, symlink resolution and external-change detection.
- Periodic local recovery snapshots for modified buffers. Recovered content opens as an untitled copy, preserving existing disk files.
- In-document find/replace, VS Code-style file/command shortcuts and Sublime-style next/all occurrence selection, additional carets, split selection into lines and uniform multi-cursor edits with undo/redo.
- Literal project search (UTF-8 files under 2 MB; up to 20,000 indexed files / 500 matches), text-based document symbols and Git status, diffs, staging, commits and graph history.
- SwiftTerm PTY terminal with the project directory passed as a process parameter.
- Native Vim subset: Normal/Insert/Visual/Visual Line/Visual Block, basic character/line/word motions, counts, dd/dw/d$/yy, put, deletion, undo/redo, insert entry and a small Ex command set.
- Optional iCloud Drive preference file with an explicit allowlist and per-setting merge. No document or credential sync.
- Local packaging, Developer ID signing, notarization and GitHub release scripts.
- GitHub update checks, independent automatic download/install switches, checksum and signing-identity verification, and an installer helper that waits for normal quit and retains the previous app. Signed download, verification and install/restart passed with a disposable baseline.
- Background file decoding, an incremental line index and noncontiguous native text layout. Large-file performance remains under measurement and is not claimed to match Sublime.

- Image preview and live Markdown/HTML right-side previews with local assets.
- Live Chinese/English UI selection, custom wordmark, installed monospace font discovery and the native font chooser.
- Initial read-only runtime/package manifest and Git tools, plus native system metrics. Package modifications, databases and task chains remain open.

- SSH config discovery, remote browsing/new files/edit/save with conflict detection, remote filename search and a terminal. Remote file protocol requires Python 3 and has a 16 MiB per-file limit.
- Run/stop panel with live PTY output, local/remote commands, isolated WebKit preview and loopback-only SSH port forwarding.
- Native Git panel with working/index diffs, stage/unstage, commits, branches, fetch/fast-forward pull/push and a parent-linked graph for the latest 150 commits.
- Rectangular column selection, distributed multiline paste and Vim visual/block multi-position editing.

## Added in 0.1.4

- Project Tools constraint-crash regression, structured three-pane Git changes/graph UI and hunk staging.
- Real remote project folder selection and lazy multi-level tree; local/remote startup restoration choice and clear activity selection.
- Bidirectional Markdown scroll coordination and one compressed rollback with legacy app migration.
- Pure Swift operator/text-object/count composition, registers, character find, marks, repeat, insertion undo, normal/insert macros, Replace mode, forward/backward/word search and a bounded Vim-pattern/Ex substitute implementation.
- Visual text objects/counts/find, multi-caret text-object changes/counts and native VS Code line commands.
- Differential system-Vim fixtures, hidden native rendering, actual SSH project/runner acceptance and regression tests.

## Added in 0.1.5

- Selected remote folders open directly; remote Git routes to its data transport and workspace instead of a folder picker.
- Responsive layer-backed scrolling across native scroll areas; display-linked window drawing and terminal updates track each screen's refresh capability.
- Reused remote entry cells and cached folder symbols; callback/layout measurements recorded with explicit presentation limits.

## Still open

The original full-editor goal is **not complete**. In particular:

- Complete Vim editing compatibility: full regex/Ex and remapping, complete block-register semantics, visual/Replace macros and remaining compound operations. Vimscript/Vim9 and VSIX hosting are outside the current implementation.
- Full multi-cursor/column selection behavior, AST-level folding refinements, minimap, comprehensive language-server coverage, DAP, graphical three-way merging and comprehensive settings/keybinding management.
- Per-workspace restoration of all files, split sessions and scroll/cursor state. Recovery snapshots currently restore as untitled copies.
- Encoding selection/conversion UI and mixed-line-ending normalization. Saving mixed endings is intentionally blocked until the format can be chosen explicitly.
- Project replacement previews, cancellation-aware large-project indexing/search and larger-file performance acceptance. Current scans exclude common generated directories and have explicit caps.
- Two-Mac iCloud delivery and concurrent-edit acceptance, input-method acceptance, complete terminal TUI/shell/lifecycle coverage, accessibility audit, large-file benchmarks and Intel runtime acceptance.

Universal compilation does not establish Intel runtime acceptance. A signed and notarized preview does not establish final product acceptance.

Public 0.1.7 DMG/ZIP SHA-256 matched the release checksums. The downloaded app passed code-signature, stapled-ticket and Gatekeeper verification; the DMG passed integrity verification. Temporary extracted apps were unregistered and removed. The website detected 0.1.7 automatically and the Chinese/English guide was verified after deployment. GitHub API acceleration succeeded through both gh-proxy endpoints; ghfast asset acceleration succeeded and unsupported API requests fell through to the next endpoint.
