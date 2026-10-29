# Native code intelligence

Linvell implements the editor-side language-client workflow in Swift/AppKit. Language servers supply each language's semantic index and project rules; the editor does not approximate those results with project-wide string replacement. Lexical highlighting and ordinary editing remain independent of a language server.

## Project and host identity

Project Settings uses the same action beside the project name for local and SSH folders. Project Tools also links to that action and executes its reports on the selected host. Per-language profiles stay in `.linvell/settings.json` on the code host. Root language settings such as `python.analysis.typeCheckingMode` and language-scoped `linvell.languageServerSettings` are merged into LSP configuration; comments and unrelated JSONC remain intact. `${workspaceFolder}` and `${userHome}` expand against the selected host. Executable approval remains per project, host and language; changing analysis settings does not revoke an existing executable approval.

Matching executable, arguments, interpreter and configuration share one backend in a workspace. This includes JavaScript/TypeScript when their profiles match. Different profiles retain separate sessions. Closing the last synchronized document releases all aliases, the process and the associated file watchers.

## Index lifetime and changes

- Negotiate server capabilities and UTF-16 positions. Honor full/incremental change synchronization, open/close and save options.
- Send minimal UTF-16 changes for incremental servers. Preserve surrogate pairs, line endings and monotonically increasing document versions.
- Cancel queued work and outstanding JSON-RPC requests; discarded hover/completion/navigation results cannot change newer editor state.
- Use filesystem events locally. Remote watchers compare source metadata in the background every 15 seconds, retain cached metadata across network errors and use a digest to avoid retransmitting an unchanged index. Neither watcher reads source contents to construct a second semantic index.
- Notify the server about external create/change/delete and saved-file changes. Refresh changed `.linvell/settings.json` through the same configuration lifecycle.
- Display connection and provider-reported analysis progress. “Connected” describes the transport, not proof that every file has finished indexing.
- Support push diagnostics and capability-negotiated pull reports with result IDs, refresh requests and related documents. The Problems picker includes unopened files and rejects stale versions and messages from a previous host/workspace.
- Recover a failed backend on a later request; Restart Language Services explicitly resets the current workspace's sessions.

## Native interactions

| Operation | Shortcut |
| --- | --- |
| Definition / references | F12 / Shift-F12; Command-click also opens a definition |
| Back / forward | Option-Left / Option-Right; Control-minus / Control-Shift-minus remain supported |
| Document symbols / workspace symbols | Command-Shift-O / Command-T |
| Implementation | Command-F12 |
| Completion / parameter hints | Control-Space / Command-Shift-Space |
| Rename | F2 |
| Format document | Option-Shift-F |
| Problems | Command-Shift-M |

Declarations and type definitions are available in Go. Document symbols use language-service ranges; workspace search queries the active workspace's live language backends and deduplicates results. Parameter hints follow each provider's trigger characters. Formatting and symbol rename preserve native undo and auto-save behavior. Rename preparation is honored when advertised. Import aliases follow the language service's semantic scope; renaming an exported declaration can update dependent files, whereas renaming a local import alias may intentionally stay local.

Mouse hovers are nonactivating native panels with compact code text, not modal popovers. They close on leaving the symbol/editor, scrolling, typing or switching windows. A request-generation check prevents late responses reopening them. Slower SSH reads can populate an inactive tab but cannot steal focus after the user navigates elsewhere.

The welcome page keeps up to twelve recent local/SSH projects, deduplicated in most-recent order. SSH entries include a Remote prefix, host and path and reopen in the same window. Existing installations migrate the last workspace record; earlier versions did not retain a complete project history. This history stays on this Mac.

## Limits

The active server must support the requested operation; the client reports unsupported capabilities rather than substituting textual guesses. Per-file language analysis is bounded at 2 MiB, rename at 500 files/32 MiB, incoming diagnostics at 500 per file/10,000 per workspace, and source metadata watches at 20,000 remote files. Cached remote metadata survives refresh errors. Untitled buffers need a saved path for project language analysis. The semantic engine, compiler flags and dependency index remain properties of the selected language server/toolchain. This is not a VSIX extension host or a claim of complete VS Code extension compatibility.

## Source references and verification

Behavioral references (independently implemented in Swift):

- [VS Code hover lifecycle](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/hover/browser/contentHoverController.ts)
- [VS Code navigation history](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/services/history/browser/historyService.ts)
- [VS Code recent-workspace welcome page](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/welcomeGettingStarted/browser/gettingStarted.ts)
- [VS Code language-client lifecycle](https://github.com/microsoft/vscode-languageserver-node/blob/main/client/src/common/client.ts)
- [Negotiated text synchronization](https://github.com/microsoft/vscode-languageserver-node/blob/main/client/src/common/textSynchronization.ts)

Regression tests exercise actual hover dismissal, nonactivating panels, Option-arrow navigation, late remote reads, shared-backend teardown, metadata digest reuse, UTF-16 changes, protocol cancellation and diagnostics negotiation. Opt-in acceptance uses real TypeScript/Python/clangd/SourceKit services and disposable SSH fixtures; screenshots and green mocks alone are not semantic-index proof.
