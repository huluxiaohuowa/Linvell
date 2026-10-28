# Linvell

A native macOS editor built in Swift and AppKit. The workspace follows the familiar activity-bar, explorer, editor-tab and terminal-panel structure, with an independent visual identity and a gourd-inspired icon.

**Early development preview.** Full Vim compatibility and the complete development-tool workflow remain in progress. See [development status](docs/STATUS.md).

## Run locally

Requires macOS 15.6+, Xcode and its command-line tools.

```sh
./script/build_and_run.sh
swift test
```

The Codex Run action uses the same script. Build outputs are kept outside the repository under `~/dev/build/linvell`. `--demo` opens the public sample workspace, `--build-only` stages the app without launching, and `--debug` starts LLDB.

## Appearance and preferences

Open **Linvell → Settings** (`⌘,`) for appearance, editor, Vim and iCloud preferences. Built-in themes: Linvell Dark, Nord, Linvell Light and Solarized Light. Default editor text is 15 pt. Sidebar, split editor and terminal panels are resizable.

iCloud Drive can synchronize the preference allowlist in `Linvell/Preferences.json`: theme, font, text size, wrapping, line numbers, indentation and Vim mode. Preferences are merged per setting using their modification times. The sync switch and machine-specific layout stay local. Documents, recovery snapshots, project paths, terminal environment and credentials never enter this preference file. iCloud Drive must be available; actual delivery to another Mac is managed by iCloud and needs cross-device verification.

## Distribution

Build and package **locally**, then distribute through [GitHub Releases](https://github.com/huluxiaohuowa/Linvell/releases). There is no GitHub runner app build and no App Store upload. The local release script reuses only the team-wide Developer ID and notarization credentials in `~/.apple.json`, in a temporary protected signing keychain.

```sh
python3 script/release.py --version 0.1.0-preview.1
# After reviewing the resulting artifacts and release notes:
python3 script/release.py --version 0.1.0-preview.1 --publish
```

The script runs tests, builds a Universal app, signs with Hardened Runtime, submits for notarization, staples the ticket, checks Gatekeeper, and creates ZIP/DMG artifacts with SHA-256 checksums. `--publish` pushes the committed source and creates a GitHub prerelease. Credentials are never committed or uploaded to GitHub.

Official website: [linvell.fuluwa.top](https://linvell.fuluwa.top/). SwiftTerm and its license are recorded in [third-party notices](Resources/ThirdPartyNotices.txt).
