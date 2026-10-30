# Agent native terminal and sidebar acceptance — 0.2.10

The 0.2.9 embedded DSH website was rejected after user reports of the wrong interface, poor layout and unresponsive creation. This revision removes that view and uses the existing SwiftTerm terminal for every provider.

## Local acceptance

- All five providers: fixture tests create sidebar rows before any prompt, retain two independent PTYs, switch without spawning a replacement and merge a known saved ID with the live row.
- Missing CLI: all five choices show installation guidance and a guide button before starting; DSH separately identifies missing TUI profiles. No automatic package installation is performed by Linvell.
- DSH: missing-TUI repeated clicks create no web processes; ready TUI uses over 70% of the workspace height; repeated startup clicks create one process; the same terminal title on resume clears the startup watchdog.
- Installed source TUI: real stored-account response is verified from the completed persisted assistant event, then stopped and restored through the original ID with assistant history intact. A terminal redraw of the user prompt is insufficient evidence.
- Actual on-screen Codex: new row before prompt, completed sentinel response, title update and one live row merged with its saved record. Double-click reuses the same terminal.
- Actual on-screen DSH: blank terminal session, completed sentinel response, readable input/output and a single live sidebar record. Stopped-session restoration displays the original reply and remains running beyond the 30-second startup deadline.
- Session binding reads process-parent metadata and open session-file names. It does not infer identity from similar titles or timestamps. Current Codex's shared daemon otherwise makes ownership ambiguous; supported CLIs use `--no-daemon` (capability checked).
- Old QA app registrations and their individual privacy grants were reset, preserving the installed application's grants. System Settings visibly showed one Linvell entry afterward. Debug launches now pass `-iCloudSyncEnabled NO`; no new QA bundle identifiers are introduced.

## Installed dependency and limits

DSH `0.2.1-rc.5`; dsh-TUI upstream commit `83fcf892d49c4f4e5b05fab2936fac2241bad579` built and packed locally, then installed into the user DSH TUI profile through DSH's plugin command. Its executable points into that installed profile, not a scratch source checkout. The npm `0.17.0` package had incompatible peer declarations; matching package version strings are not proof of rc.5 compatibility. An alternative published TUI trial was retired after peer mismatch warnings. Existing account authentication was reused, without reading or copying secrets. The initial onboarding API-key prompt was skipped; account model selection and a real reply established working authentication.

Real-account acceptance covers local Codex and DSH only. Other providers use fixture tests. Remote TUI authentication and provider configurations not emitting an identifiable session file are not guaranteed. Blank sessions that the provider has not persisted are only retained by the current workspace. The Codex test displayed a pre-existing hook exit-127 warning after the correct reply; this change does not alter user hooks. The installed release app is not replaced by acceptance builds.

## Validation results

Final Swift suite: 295 tests, 29 environment-dependent skips, zero failures (116 UI + 179 core). Release-script suite: 14 tests passed. Shell syntax and whitespace checks passed. The final installation hint was also checked in the actual app window and the executable path restored afterward.

## Validation logs

Build and test artifacts live outside the repository under the Linvell build directory. Final Swift suite, release-script tests, installed-TUI acceptance and actual-window screenshots are recorded there. Public package verification is performed after release publication and recorded in STATUS.md.
