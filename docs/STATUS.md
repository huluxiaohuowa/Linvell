# Development status

2026-10-28 · 0.1.0 preview series

## Implemented foundation

- Native AppKit workspace with activity rail, explorer, file tabs, shared-storage split editors and resizable native panes.
- Explicit file-tree indentation, disclosure controls and hierarchy guides.
- Four built-in light/dark themes, 15 pt default text, font family/size controls and categorized settings.
- UTF-8 / BOM / UTF-16 text loading, CR/LF/CRLF preservation, atomic file writes, permission preservation, symlink resolution and external-change detection.
- Periodic local recovery snapshots for modified buffers. Recovered content opens as an untitled copy, preserving existing disk files.
- In-document find/replace, an initial next-occurrence selection command, fuzzy file picker and searchable command picker.
- Literal project search (UTF-8 files under 2 MB; up to 20,000 indexed files / 500 matches), text-based document symbols and read-only Git status.
- SwiftTerm PTY terminal with the project directory passed as a process parameter.
- Native initial Vim command engine: Normal/Insert, basic character/line/word motions, counts, dd/dw/d$/yy, put, deletion, undo/redo, insert entry and a small Ex command set.
- Optional iCloud Drive preference file with an explicit allowlist and per-setting merge. No document or credential sync.
- Local packaging, Developer ID signing, notarization and GitHub prerelease scripts.

## Still open

The original full-editor goal is **not complete**. In particular:

- Full Vim behavior, Visual/Replace modes, operators/text objects, macros, registers beyond the initial register, mappings, Vim regex, full Ex, Vimscript/Vim9 and differential compatibility coverage.
- Full multi-cursor/column selection behavior, folding, minimap, robust language-aware syntax parsing, LSP, DAP, Git write workflows, tasks, remote files, previews and comprehensive settings/keybinding management.
- Per-workspace restoration of all files, split sessions and scroll/cursor state. Recovery snapshots currently restore as untitled copies.
- Encoding selection/conversion UI and mixed-line-ending normalization. Saving mixed endings is intentionally blocked until the format can be chosen explicitly.
- Project replacement previews, cancellation-aware large-project indexing/search and larger-file performance acceptance. Current scans exclude common generated directories and have explicit caps.
- Two-Mac iCloud delivery and concurrent-edit acceptance, input-method acceptance, complete terminal TUI/shell/lifecycle coverage, accessibility audit, large-file benchmarks and Intel runtime acceptance.

Universal compilation does not establish Intel runtime acceptance. A signed and notarized preview does not establish final product acceptance.
