# Agent selection and installation guidance — 2026-10-30

## Regression proof

The original 0.2.6 SSH acceptance checked selector values and process survival, but did not assert that selecting local changed the actual displayed terminal. That gap allowed the reported defect through.

The strengthened SSH regression was run against an isolated checkout of 0.2.6. It failed on the retained remote active runtime/view after selecting local, the stale host display, the still-enabled Stop action, missing DSH guidance, and the provider selector staying on DSH after choosing a Codex session. The same regression passes on the revised source. The disposable baseline checkout was removed after recording the result.

## Acceptance cases

- Switching provider/location detaches the previous terminal and selects the last terminal for the new combination. When none exists, there is no active terminal, Stop is disabled, the prior process remains alive, and the main view explains the selected configuration.
- A three-provider/two-location matrix uses six real PTYs, including three connected over SSH to disposable fixture processes. Twelve alternating location selections assert the actual terminal object in the main view, exactly one displayed terminal, provider and host labels, enabled controls, unchanged PIDs and surviving background processes. Menu selection synchronizes the provider/location controls. Stop followed immediately by another selection stops only the originally selected process.
- Existing local runtime registration in this matrix represents reattaching a previously opened runtime; it does not bypass the production mount requirement for new local sessions on SSH projects. Real provider model calls and successful physical SSHFS mounting are not claimed by this matrix.
- Missing DSH task input keeps New Session actionable, gives an explicit message, focuses task input and creates no process. Selecting an existing running session does not require entering a new task.
- Local mode on SSH projects shows installation guidance and visible mount controls. New Session attempts to connect the project rather than silently doing nothing. On the dependency-free test Mac, it reports missing SSHFS without starting a CLI or installing system software.
- Installation detection distinguishes absent files, non-executable files, real executables, directory impostors, and presence of macFUSE installation files. Installation discovery does not assert that a filesystem backend is authorized or a mount is working; live mount validation remains authoritative.
- Background history discovery uses its own sidebar status. It cannot overwrite an actionable launch/prerequisite error or the active runtime status. Mount callback guards also check the original requested configuration and current workbench visibility before launching; this success-path guard was reviewed in source, while a successful physical mount remains unverified.

## Installation sources and boundary

The UI links to [macFUSE's official Getting Started guide](https://github.com/macfuse/macfuse/wiki/Getting-Started) and exposes the [current official Homebrew Cask command](https://formulae.brew.sh/cask/sshfs-mac), `brew install --cask sshfs-mac`, whose declared dependency is macFUSE. Kernel/FSKit backend setup is left to the official guide and the user's system prompts. Linvell does not install a driver, change system security configuration, or reboot the machine.

No standalone test Linvell app instances were opened. The installation view is rendered by an offscreen native test window that is closed during teardown. Physical SSHFS mounting remains unverified on this Mac because the dependencies are not installed.

Final broad local regression run: 108 native/UI tests and 172 core tests, zero failures and two environment-dependent skips (physical display cadence and remote Git mutation without a disposable Git repository). The demonstrated selection matrix, failing baseline reproduction and missing-dependency actions are the acceptance evidence for this change; the overall count is not a substitute for those cases.


## CI artifact isolation correction

The first release CI run failed before publication. The installation snapshot test wrote to a task-specific build directory that happened to exist on the development Mac and was absent on the runner. The test now creates its destination, honors `LINVELL_UI_ARTIFACT_DIR`, and otherwise uses the standard build directory. A local rerun with a newly absent nested artifact directory passed. Build diagnostics now retain early compiler/XCTest errors ahead of the bounded log tail; the diagnostic regression and release-script checks passed. Signing/notarization tool output remains protected.


## Published artifact verification

The corrected [0.2.7 release/Homebrew workflow](https://github.com/huluxiaohuowa/Linvell/actions/runs/41018296152) succeeded, including its complete test stage. [Release v0.2.7](https://github.com/huluxiaohuowa/Linvell/releases/tag/v0.2.7) is public. The downloaded app reports 0.2.7 and contains `x86_64 arm64`; strict/deep signature verification, Gatekeeper assessment and stapled ticket validation all passed. The signed 0.2.6 → 0.2.7 upgrade test passed without replacing the installed app.

The Homebrew Cask reports 0.2.7. Its checksum matches the downloaded ZIP: `e2b7d0d73f118c6257c1bfff22949cc31b1304c1044b7aaa56497d135c29f439`. No standalone test Linvell instances remain. System filesystem software was not installed as part of this work; physical SSHFS mounting still requires separate acceptance after installation.
