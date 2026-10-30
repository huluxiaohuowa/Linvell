# Agent project context — 2026-10-30

## Fixed behavior

Previously, opening Agents returned the existing workbench immediately whenever any session was running. A local workbench could therefore remain active after connecting to an SSH project, keeping the old history and hiding the local/SSH execution selector.

Workbenches are now retained by project directory and SSH host. Connecting to SSH, selecting a remote folder, resolving its canonical root, and selecting a local project synchronize the current workbench. If the main editor was showing an Agent, it switches to the newly selected project's workbench. The existing sidebar choice is preserved; entering the Agents sidebar shows the current project's configuration and session list. A new SSH workbench exposes the local/SSH execution selector and starts in SSH mode. Other projects' PTYs remain alive, and returning to their project restores the same workbench. Shutdown/quit confirmation and theme changes cover retained workbenches too.

## Validation

Final full local run: **276 tests, zero failures, two skipped** (105 native/UI tests and 171 core tests). Skips remain the opt-in physical display cadence check and remote Git mutation without a disposable Git repository.

New regression coverage:

- A local PTY remains running while the main workspace and left session list change to another project's workbench. The remote execution selector is visible and enabled; different SSH hosts with the same directory are isolated.
- Returning to the original local project restores the original terminal and PID. Window-level shutdown stops retained sessions as well as the visible project's sessions.
- A real SSH transport fixture exercises the actual connect-to-SSH action, remote session discovery through the Codex metadata protocol fixture, and a remote PTY that reports its working directory. Switching execution location between local and SSH remains possible while both local and remote PTYs run. Local launch without a live mount stays disabled. Returning to the local project preserves both processes until explicit shutdown.

This is transport/lifecycle acceptance with a disposable provider-protocol fixture; it does not claim real model-provider calls on SSH or a physical SSHFS mount. Source was rsynced before remote tests. No remote Git command ran. No standalone test Linvell instances were launched or left running.

## Homebrew documentation

The main application README now presents bilingual install/upgrade commands. Website commit `31e5eb8` adds a homepage entry and installation section, updates the update FAQ, both Markdown guides, the rendered bilingual guide and the website README. Five website regression checks passed. The deployed Chinese homepage and guide were verified in one hidden browser tab, which was then closed.


## Publication verification

[0.2.6 release](https://github.com/huluxiaohuowa/Linvell/releases/tag/v0.2.6) and [release/Homebrew workflow](https://github.com/huluxiaohuowa/Linvell/actions/runs/41013036855) succeeded. The downloaded app reports 0.2.6, includes `x86_64 arm64`, and passes strict/deep signature verification, Gatekeeper assessment and stapled notarization-ticket validation. A signed 0.2.5 → 0.2.6 upgrade test also passed, without replacing the installed application.

The Homebrew Cask reports 0.2.6, and its SHA-256 matches the downloaded archive: `7c553096dc4c3d8a9b8820cd84556e93253bbc3b4825d5495c8a641a5defb701`.

Website commit `124cdd9` also adds the source repository to the homepage navigation. The live English desktop navigation and expanded mobile menu in both languages were verified. The temporary viewport override was cleared and the hidden verification tab was closed.
