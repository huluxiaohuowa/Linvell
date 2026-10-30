# P6 plugin installation and management acceptance

2026-10-30 · source on main after 0.2.0; no new public application release.

## Implemented

Native Plugins → Manage Plugins and Settings → Plugins entry points. Installed/catalog/source tabs with search; local ZIP/folder, HTTPS ZIP URL and SHA-256 catalog installation; explicit trust and persistent enablement; restart restoration; reload, settings/logs, manual update, previous-version rollback and uninstall. Sources can be added, edited, removed and refreshed. Editing preserves source identity; re-adding the same removed source reconnects its installed packages. A removable official resource-example source is provided by the website.

Managed immutable package revisions use an atomic, file-locked registry. Staged copies are validated before trust review; approved enabled command hosts pass a handshake before registry selection changes. Invalid downloads, checksums, archives, stale writes and preflight failures keep the selected old revision. A disabled package does not execute during installation. Runtime failures remain visible through logs and explicit reload/rollback.

Theme/icon choices persist for managed packages. Uninstall removes active/previous copies and saved resource selections; optional data cleanup is scoped to that plugin's local data, retaining project configuration and external tools. See [format and limits](../plugins/management.md).

## Verification

- Debug app build succeeded with the existing build script, output/cache under `~/dev/build/linvell`.
- Relevant regression selection ran 45 XCTest cases: 40 passed, 5 opt-in external-tool/SSH cases skipped, zero failures. Includes existing P1–P5 and language lifecycle coverage, nine new core-store cases and two managed-workspace cases. Updated the existing menu expectation for the new manager entry.
- Core fixtures cover stored/Deflate ZIPs, executable modes, traversal/symlink/CRC/inflation rejection, source/direct URL updates over an isolated loopback server, SHA mismatch, stale revisions, bad handshake, package-copy independence, rollback, restart state, source removal/re-add, isolated explicit data cleanup and corrupt registry rejection.
- Workspace tests cover loading across controller restart, saved themes/icons, enable/disable across workspaces and uninstall cleanup, using an injected isolated store.
- Real native app acceptance used a separate QA bundle and isolated `LINVELL_PLUGIN_HOME`. Installed local resource package 1.0.0, disabled/enabled, upgraded to 1.0.1 and rolled back to 1.0.0. Quit/relaunch automatically restored its status entry and both installed rows without developer loading.
- The manager downloaded the live official HTTPS catalog and installed its resource ZIP with SHA verification. Direct HTTPS ZIP replacement also passed review/installation. Source add/edit/remove passed; editing and refreshing retain selection. Both test packages were uninstalled through confirmation sheets, leaving an empty installed list and no managed revision directories. The QA app was quit and unregistered afterward.
- Website source/package integrity and existing release metadata tests: five passed. Bilingual management guide documents the source-preview/public-release distinction.

Evidence logs: `~/dev/build/linvell/plugin-manager/{regression-tests,qa-build,lifecycle-tests,store-tests}.log`. The installed production app and personal plugin registry were not replaced. Other unrelated working-tree edits were preserved.

## Boundaries

This is explicit user-controlled distribution, not an automatic updater or third-party marketplace. No VSIX/Nova/Vim compatibility, publisher signatures, OS sandbox, automatic dependency installation or iCloud plugin synchronization is added. Code plugins retain the user's OS access. External-tool and Linux/SSH behavior was not re-certified by this change; existing dedicated P4/P5 acceptance remains applicable. Public 0.2.0 does not include P6 until a subsequent release.
