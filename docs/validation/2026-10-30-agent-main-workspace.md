# Linvell 0.2.4 — Agent integration and main-workspace acceptance

This release includes the previously uncommitted Agent implementation, editor/file-monitor changes, performance improvements, tests, documentation and project design seed. It also retains 0.2.3's installation-aware updater and automatic Homebrew publication.

## Main-workspace behavior

- The left activity bar has an Agents entry; the toolbar and command palette retain their entries.
- Provider, CLI installation, optional agent home and project session selection appear in the workspace sidebar. The selected CLI runs in the main workspace, with no separate Agent window.
- The workspace owns the Agent view and process independently of editor views. Opening files and switching activity sections do not replace the PTY or process. Returning to Agents attaches the same view and terminal; Stop or workspace termination ends the process.
- Repeated requests share pending session discovery. A regression test verifies 100 immediate reopen/refresh requests use the same request identity and that a later refresh remains possible.
- Clean files changed by the Agent reload while unsaved text retains conflict protection. Expanded directories refresh without a full-project scan. Tab rows retain their native views across selection, save and reorder.

## Evidence

The existing five-provider parsing, metadata, session naming, worktree and path-mapping tests were included. Additional acceptance covers real installed Codex metadata, SSH metadata through a disposable protocol fixture, original argument/cwd preservation in the native terminal, Agent edits and tree refresh, dirty-buffer protection, workspace attachment without a new window, and process/terminal identity across file browsing.

An isolated native app was operated through the actual left Agents button. A real installed Codex CLI reached its interactive prompt inside the main editor window. Clicking an open file returned to the editor; clicking Agents restored the running terminal. No model turn was submitted. This is visible UI/runtime acceptance, separate from metadata fixtures and compilation.

The full local suite completed 100 native UI tests and 171 core tests with zero failures and two explicitly excluded environment-dependent tests. It enables available real language services, plugin tools, managed-tool installation, SSH fixtures, installed Codex metadata and Homebrew source checks. The release's signed-upgrade archive and Homebrew publication are verified after CI produces them.

Boundaries: five-provider authentication and real model/context-restoration calls are not claimed; SSHFS requires an existing installation and live mount and was not exercised; the physical display-cadence test and remote Git mutation test remain excluded. No remote git command is used. CI separately builds the signed/notarized Universal application and updates the tap after publication.
