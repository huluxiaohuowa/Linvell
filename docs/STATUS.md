# Development status

2026-10-28 · 0.1.2

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

## Still open

The original full-editor goal is **not complete**. In particular:

- Full Vim behavior, Replace mode, full operators/text objects, macros, registers beyond the initial register, mappings, Vim regex, full Ex, Vimscript/Vim9 and differential compatibility coverage.
- Full multi-cursor/column selection behavior, folding, minimap, robust language-aware syntax parsing, LSP, DAP, advanced Git history editing and comprehensive settings/keybinding management.
- Per-workspace restoration of all files, split sessions and scroll/cursor state. Recovery snapshots currently restore as untitled copies.
- Encoding selection/conversion UI and mixed-line-ending normalization. Saving mixed endings is intentionally blocked until the format can be chosen explicitly.
- Project replacement previews, cancellation-aware large-project indexing/search and larger-file performance acceptance. Current scans exclude common generated directories and have explicit caps.
- Two-Mac iCloud delivery and concurrent-edit acceptance, input-method acceptance, complete terminal TUI/shell/lifecycle coverage, accessibility audit, large-file benchmarks and Intel runtime acceptance.

Universal compilation does not establish Intel runtime acceptance. A signed and notarized preview does not establish final product acceptance.
