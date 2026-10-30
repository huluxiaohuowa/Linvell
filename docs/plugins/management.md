# Plugin installation and sources

New on main after 0.2.0; requires a source build until a subsequent application release.

Open Plugins → Manage Plugins or Settings → Plugins → Manage Plugins. Install a local ZIP/folder, an HTTPS ZIP URL, or a catalog entry from a configured HTTPS source. The built-in Linvell Examples catalog is `https://linvell.fuluwa.top/plugins/catalog.json`. Downloads and catalog browsing do not run code. Review the exact name, ID, version, permissions, execution location and replacement version before installation; the enable checkbox explicitly authorizes loading now, in other workspaces and after app restart. Development folder loading remains temporary.

Installed packages support search, persistent enable/disable, reload, settings/logs, explicit update, one previous-version rollback and uninstall. Manual ZIP installs can be updated by choosing a newer ZIP; URL installs recheck their URL; catalog installs stay pinned to their source ID. Editing a source URL preserves that identity. Removing a source keeps its installed packages. No background automatic installation/update occurs.

A source catalog is UTF-8 JSON, schemaVersion 1, with name and plugins. Each entry has id/name/version/url/sha256 and optional description. IDs and versions must exactly match the ZIP manifest; versions have three numeric components with optional prerelease. HTTPS is required, including redirects, and credential-bearing URLs are rejected. SHA-256 must contain 64 hexadecimal characters. A publisher should make the archive available before changing its catalog entry.

```json
{
  "schemaVersion": 1,
  "name": "Example Plugins",
  "plugins": [{
    "id": "dev.example.theme",
    "name": "Example Theme",
    "version": "1.0.0",
    "url": "https://example.com/theme-1.0.0.zip",
    "sha256": "REPLACE_WITH_THE_REAL_64_CHARACTER_SHA256",
    "description": "A declarative native theme."
  }]
}
```

Create a ZIP with `ditto -c -k --keepParent /path/to/package ~/dev/build/linvell/plugin.zip`, then compute `shasum -a 256 ~/dev/build/linvell/plugin.zip`. Include exactly one plugin.json at the ZIP root or in its package wrapper directory, with all executable/resources it declares. Stored and Deflate ZIPs are supported. Encryption, ZIP64, links, traversal, duplicate names, CRC and exact decompression-size violations are rejected. Limits: compressed archive 128 MiB, expanded total 256 MiB, each file 64 MiB, 4,000 entries; catalog 1 MiB/1,000 entries; 50 sources and 500 installed plugins.

Installations copy files into `~/Library/Application Support/Linvell/InstalledPlugins`, with immutable revision directories and an atomically replaced, file-locked registry. Uncommitted candidates cannot replace the active version. Download/validation/checksum/ID/version/stale-write/command-host handshake failures leave the installed version selected. Post-activation tool/runtime failures use explicit logs/reload/rollback and never automatically replay tasks. One previous revision is retained; rollback exchanges it with the current revision.

Uninstall removes the managed active and rollback copies and their selected theme/icon preferences. Optional data removal clears only that plugin's local user configuration and global/workspace state under the existing Plugins data directory. Project .linvell/settings.json, externally installed CLI tools and downloaded remote execution caches are kept. Managed theme/file-icon selection persists and is restored when its installed plugin is enabled; choosing a built-in theme clears the saved plugin-theme selection. None of this installation state is synced to iCloud.

Checksums establish integrity relative to the selected HTTPS source, not a publisher signature or sandbox. Code plugins run with the user's OS access. Enabling persistent installation does not install external runtimes, CLI tools or libraries.
