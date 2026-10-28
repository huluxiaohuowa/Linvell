# Linvell 0.1.2 verification — 2026-10-28

## Exercised workflows

- Core Git fixtures exercise literal filenames, whitespace/newlines in porcelain status, stage/unstage before and after the first commit, commits, renames, branch divergence and a merge. The graph is computed from real parent hashes.
- Native AppKit tests render a four-commit merge graph and its patch in a hidden test window; table/pane sizes and completed asynchronous loading are checked. No second interactive development app is needed for these checks.
- A disposable Linux SSH workspace exercises the actual system-SSH transport, remote list/read/write, Unicode content and conflict rejection, restoring its original test content afterward.
- A native runner test starts a real Web server on that SSH host, discovers its unique test port, opens a loopback-only SSH tunnel, loads the page through the embedded preview and reads the expected fixture HTML. Stop is checked against the remote TCP service as well as the local SSH process; shutdown closes the tunnel.
- Local PTY run/stop, rectangular selection boundaries, whole Unicode graphemes, Vim Visual Block change/input and undo/redo, multi-position Vim change-word and different replacement text per selection are covered.
- The website guide was checked in the browser in English and Chinese; repository Markdown copies are provided in both languages.

## Limits

Remote files require a POSIX shell and Python 3 and are capped at 16 MiB. Column selections are capped at 10,000 rows. Git Graph loads up to 150 commits. The implementation is not a VS Code extension/LSP/debug host, full Vim compatibility or all Sublime Merge operations. Physical mouse gestures and alternate SSH authentication/jump-host topologies have not all been exercised. Intel runtime acceptance remains open.

The distribution manifest records the actual local Universal build, signing, notarization and Gatekeeper results; successful tests alone are not a notarization claim.
