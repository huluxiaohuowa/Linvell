# Concurrent Agent sessions — 2026-10-30

## Behavior

The left sidebar retains provider selection, New Session, session search, saved-session titles, the session table and Resume Session. Optional CLI/home/mount configuration is collapsible. The main workspace selects among retained terminal runtimes; switching selection never shuts down another runtime. Each runtime captures its provider, host, executable, home, session identity, directory and mount mapping. Stop's delayed fallback captures the original terminal rather than whichever terminal is later selected.

The terminal delegate forwards SwiftTerm input, resizing, clipboard, title and directory notifications while routing file links through the owning WorkspaceController. Relative paths use the originating runtime's directory. HTTP(S) links use the browser. Image files use Linvell's existing image preview. Plain paths can be selected and opened with Open Selected File; OSC 8 links use Command-click. No application-wide file association is changed.

## Evidence

Final full local run: **274 tests, 0 failures, 2 skipped** (103 native/UI tests and 171 core tests). The skipped checks are opt-in physical display cadence and remote Git mutation without a disposable Git fixture. Build output and logs remain outside the repository under the task's build directory.

- Three actual PTYs run together across two provider configurations. Tests create a new session while another runs, reattach a known saved session without a duplicate process, switch providers during discovery, receive background output, stop one session then immediately select another, and stop all on shutdown.
- Native delegate dispatch opens a text file at its requested line and an image in the same workspace/window. Returning to Agents retains the original PID. An iTerm2 inline PNG is decoded into the terminal buffer, remains after a session switch and is rendered into a bitmap artifact with asserted colored pixels. The macOS stripe renderer now writes into its retained bitmap instead of a separate focus cache, fixing transparent inline images. Remote-link ownership and relative path parsing are also checked.
- Installed Codex metadata and two native embedded Codex CLI sessions were exercised. A separate ephemeral read-only Codex execution returned the exact requested model reply. This is one-provider model acceptance, not an end-to-end model call claim for every provider.
- Installed DSH runtime and real compressed logs returned five project sessions with five saved titles. Only counts were recorded. Regression fixtures include concatenated frames, a large intervening event, a later rename and an incomplete final frame. Both the installed DSH Node codec and newer Node codec behavior were considered.
- Existing real language-service, managed-tool, plugin/SSH, file refresh/conflict protection, editor interaction and updater regression checks passed. Source was rsynced before remote acceptance. No Git commands were run remotely.
- Physical SSHFS mounting was not exercised; existing mount identity/namespace validation tests passed. This check remains separate from SSH CLI execution and remote file access.

## Design references

Reviewed behavior and owning source in [CloudCLI's session store](https://github.com/siteboon/claudecodeui/blob/main/src/modules/chat/hooks/useSessionStore.ts), [Orca's session model](https://www.onorca.dev/docs/model/agents-sessions) and [Orca's file-link routing](https://github.com/stablyai/orca/blob/main/src/renderer/src/components/native-chat/native-chat-file-link.ts). Agent Deck and Claude Squad also separate session creation, attachment and stopping. Linvell keeps its native PTY implementation; no third-party application code was copied.

## Published artifact acceptance

[Release v0.2.5](https://github.com/huluxiaohuowa/Linvell/releases/tag/v0.2.5), source `f4cc002c6eb17b669b0a26cf97b96f88cbaef0fb`. [Release and downstream Homebrew jobs](https://github.com/huluxiaohuowa/Linvell/actions/runs/41007572859) both succeeded.

The downloaded release reports 0.2.5 and contains `x86_64 arm64`. Deep/strict code-signature verification, Gatekeeper assessment and stapled notarization-ticket validation all passed. The separately exercised signed 0.2.4 → 0.2.5 upgrade passed, retaining one compressed rollback and cleaning temporary application registrations; the installed application was not replaced.

The published Homebrew Cask reports 0.2.5. Its archive SHA-256 matches the independently downloaded ZIP: `676a018cebc5cae456654a745117ff0ddd933e9b5c60e488e2c69bba2e537a71`. Official Homebrew inclusion remains deferred; this is the existing self-hosted tap.
