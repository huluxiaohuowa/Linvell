# Plugin P3 — source verification

2026-10-29. Source on `main`; no new public app release or installed-app replacement. Automated native/control and wire checks and the visible local P3 interaction acceptance passed.

## Implemented

- Additive protocol 1 schemas: views, settings, themes, icons and snippets. P1/P2 command-only packages remain compatible. Resource-only packages omit the executable and use empty commands/no document events.
- Native AppKit tree/list sidebars and owned tool windows, stable item identity, expansion/selection restoration and declared command callbacks carrying view/item IDs. Updates are validated response snapshots (`viewUpdates`) from commands or `onDocumentEvent`; old state-only `onEvent` remains supported.
- Footer status entries (first three; all remain accessible from the plugin menu). Identical data is skipped, status controls and decoded icons are reused, hidden views retain only their latest model. No plugin UI code executes on the main thread.
- Native settings entry in Settings → Plugins and per-plugin forms. String/boolean/finite number/choice fields, user/workspace scope, explicit save/reload, validation, JSONC/comment preservation, conflict checks and existing local/SSH settings transport.
- Explicit session theme and file-icon selection. Eight named RGB colors, PNG/SF Symbol icons and optional extension mappings. UI icons are scoped to the package; themes/file icons apply across app windows. Stopping their owning session restores the built-in preferences/resources.
- Explicit snippet insertion, scope/prefix matching, a single editor selection, unique numbered tab stops, Tab/Shift-Tab, positions adjusted by edits within the active field, final cursor and insertion undo. Escape/external edits/owner stop end navigation.
- Stop/reload/process failure removes contributed controls, sidebar views, owned windows and caches. Old session callbacks are ignored. Tool-window Command-W closes the tool window, and Command-S in a settings form saves that form.

## Automated evidence

- Final plugin selection: 25 tests passed, zero failures (18 Core, 7 UI). The final native contribution tests were rerun after the palette cache change and passed.
- Broader regression: Core selection ran 131 tests with 11 environment/opt-in skips and zero failures. UI regression ran 81 tests with 4 skips and zero failures after updating the old five-category assertion for the new Plugins category. The additional native-form test ran separately and passed. Two unrelated GitSubmoduleTests cases were excluded from this P3 regression selection; they were not rerun.
- Coverage: data-only package loading, real packaged PNG paths and escape rejection, invalid schemas/commands/icons/themes, bounded snapshots, item identity propagation and invalid runtime UI replies, tree selection/expansion, cleanup, theme/icon restore, native form save/conflict/comment preservation, Unicode snippets, shifted tab stops, insertion undo and namespace separation between a panel named `settings` and the native settings window.
- Compiled HelloPlugin 0.3.0 ran over real stdin/stdout: initialization capabilities, document-event status update, replacement list snapshot, UI item activation identity and clean EOF passed. The debug application and example built successfully.
- Chinese/English guide was rendered in the browser. All 14 section anchors and source-preview/main wording were checked; existing website release metadata tests passed (3 tests).

## Visible local acceptance

Verified in an isolated local QA app built from this source, using a scratch Swift document:

- Expanded the native tree and ran its selected guide item; the callback reported the expected view/item IDs. Refreshed the list and saw the replacement row and body text.
- Opened the native tool window, activated its selected action and closed it with Command-W while the document window remained open.
- Saved user settings with Command-S, reloaded them, then verified workspace inheritance and saved workspace string, boolean, number and choice values. The saved workspace prefix was used by the example command. Settings → Plugins exposed the form entry.
- Document edits changed the footer event counter from 1 through 7. Stopping the plugin removed its footer control and menu contributions.
- Selected Plugin Forest and the spark file icons; the visible editor palette and explorer/tab icons changed. Stopping restored the built-in palette and Swift icons.
- Inserted Greeting Function, edited its first placeholder, navigated forward/backward with Tab/Shift-Tab, completed navigation and undid the typing and insertion to restore the original document.
- Loaded Examples/ResourcePack directly with no executable and no editor permissions. Its theme, icons and snippet worked; stopping restored the original appearance. The scratch document was restored and the QA app was closed.

## Explicit limits

- Views are full snapshots: at most 16 per package, 2,000 items per view, tree depth 16. List/panel rows are flat. Body text is at most 64 KiB UTF-8; status text is 200 characters. No arbitrary widgets, HTML, unsolicited plugin UI RPC, lazy tree-provider callbacks or dockable bottom-panel API.
- Settings support up to 32 fields and 50 choice options. Form saves write displayed schema fields to the selected scope and preserve unrelated keys/comments; closing discards drafts. Saved files determine effective values. SSH form transport is implemented through the existing writer, but live SSH acceptance was not performed for P3.
- Theme/icon choices are explicit, app-wide and session-only, not installed OS themes or synced settings. PNG assets are limited to 1 MiB and 1,024 square; no SVG/remote image loading or executable drawing callbacks. Missing SF Symbols fall back to text.
- Snippets support a 64 KiB body, up to 32 distinct stops including the final stop, indices 0–99 and one selection. Mirrors/repeated indices, nested placeholders, choices, transforms, variable expansion, automatic prefix completion and multi-cursor snippet sessions are not implemented. This is not VSIX snippet compatibility.
- Code plugins still execute as trusted local programs outside an OS sandbox. Resource declarations do not add secret storage, a marketplace, remote execution, process quotas or a physical frame-rate guarantee. Intel and physical display cadence were not tested.
