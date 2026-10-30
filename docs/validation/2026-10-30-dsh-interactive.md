# DSH interactive conversations — 2026-10-30

The previous integration forced `dsh headless` and rejected an empty task before launch. The installed CLI advertises Web, headless and automation profiles, but no shipped TUI profile. Headless also used the default API-key route despite an existing account login. These were integration errors; installing a TUI or requesting another key was not the remedy.

## Implementation and acceptance

- Launch the installed `dsh web --no-open --host 127.0.0.1 --port 0` and display its official application in an isolated WKWebView. Keep its launch URL and cookie within the runtime; never read credential values.
- Use the account metadata and official `session/initializeDefaultModel` operation before blank creation. This follows DSH's own login initialization and preserves its handling of configured provider API keys.
- Create without a prompt using `session/create`. Restore the exact session ID using the installed client's persisted selection contract. This client contract is version dependent and is covered by the opt-in installed-runtime test.
- `testDSHLaunchesInteractiveWebWithoutRequiringATask` failed against the old launch arguments and passed after the change.
- The installed-runtime test creates a blank conversation, checks its rendered identity, sends a minimal prompt through the authenticated Web RPC, verifies the assistant response in the rendered conversation, exercises the table's real double action, stops the process, and double-clicks the saved item again to verify the same ID and assistant history. No credential is supplied by the test.
- Local full Swift regression: 290 tests, 29 environment-dependent skips, zero failures. The final focused run includes the installed-runtime acceptance after removing the task field. Release-script tests: 14 passed.

Logs are under `~/dev/build/linvell/`: `dsh-interactive-red.log`, `dsh-full-tests.log`, `dsh-final-live.log`, and `dsh-release-tests.log`.

## Limits

Live DSH account acceptance covers the local installed application. SSH forwarding is implemented, but a real remote DSH account was not exercised. Other optional SSH/model fixtures remain skipped in the general suite. Build, signature, notarization and publication are tracked by the release workflow separately from this source-level acceptance.

## Published distribution

Release `v0.2.9` was published from `425cb84414eea75f2d4d532fd07b100502054b6c`. The public ZIP is 10,726,061 bytes. Downloaded artifacts passed SHA-256 verification; the extracted bundle reports 0.2.9 and includes arm64/x86_64. Strict deep code-signature validation, Gatekeeper assessment and stapled-ticket validation passed. The manifest reports notarization `Accepted`, and the unauthenticated GitHub latest-release feed reports `v0.2.9`. The installed application remains 0.2.8; publication and installation are separate.

[Release workflow](https://github.com/huluxiaohuowa/Linvell/actions/runs/41064247007) completed its release job successfully. The downstream Homebrew job runs separately.
