#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
CONFIG="${CONFIGURATION:-debug}"
BUILD_DIR="${LINVELL_BUILD_DIR:-$HOME/dev/build/linvell}"
APP="$BUILD_DIR/$CONFIG/Linvell.app"
BUILD_ARGS=(-c "$CONFIG")
if [[ "${LINVELL_UNIVERSAL:-0}" == "1" ]]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
# This is a generated bundle; start clean so removed dependencies cannot leave stale resources.
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/Linvell" "$APP/Contents/MacOS/Linvell"
cp "$BIN_DIR/LinvellUpdater" "$APP/Contents/Helpers/LinvellUpdater"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "$CONFIG" == "debug" ]]; then
  # Development launches must not compete with the installed app in Finder.
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier top.fuluwa.linvell.debug' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleDocumentTypes' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Delete :NSServices' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Linvell Dev' "$APP/Contents/Info.plist"
fi
cp Resources/Brand/Linvell.png "$APP/Contents/Resources/Linvell.png"
for wordmark in Resources/Brand/Wordmark*.png; do
  [[ -f "$wordmark" ]] && cp "$wordmark" "$APP/Contents/Resources/"
done
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
if [[ -f Resources/ThirdPartyNotices.txt ]]; then cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/ThirdPartyNotices.txt"; fi
if [[ -d Resources/FileIcons ]]; then ditto Resources/FileIcons "$APP/Contents/Resources/FileIcons"; fi
for localization in Resources/*.lproj; do
  [[ -d "$localization" ]] && ditto "$localization" "$APP/Contents/Resources/$(basename "$localization")"
done
if [[ "$CONFIG" == "debug" ]]; then
  for info_strings in "$APP"/Contents/Resources/*.lproj/InfoPlist.strings; do
    [[ -f "$info_strings" ]] && plutil -replace CFBundleDisplayName -string 'Linvell Dev' "$info_strings"
  done
fi
for resource in "$BIN_DIR"/*.bundle; do
  [[ -d "$resource" ]] && ditto "$resource" "$APP/Contents/Resources/$(basename "$resource")"
done
codesign --force --sign - "$APP/Contents/Helpers/LinvellUpdater"
codesign --force --sign - "$APP"
case "$MODE" in
  --build-only) printf '%s\n' "$APP" ;;
  run) open "$APP" ;;
  --demo) open "$APP" --args --demo "$ROOT_DIR/Samples/Welcome.swift" ;;
  --verify) open -n "$APP"; sleep 1; pgrep -x Linvell >/dev/null ;;
  --debug) lldb -- "$APP/Contents/MacOS/Linvell" ;;
  --logs|--telemetry) open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "Linvell"' ;;
  *) echo "usage: $0 [run|--build-only|--demo|--verify|--debug|--logs]" >&2; exit 2 ;;
esac
