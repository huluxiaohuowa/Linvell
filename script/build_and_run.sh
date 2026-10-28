#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
CONFIG="${CONFIGURATION:-debug}"
BUILD_DIR="${LINVELL_BUILD_DIR:-$HOME/dev/build/linvell}"
APP="$BUILD_DIR/$CONFIG/Linvell.app"
if [[ "$MODE" != "--build-only" ]]; then pkill -x Linvell >/dev/null 2>&1 || true; fi
BUILD_ARGS=(-c "$CONFIG")
if [[ "${LINVELL_UNIVERSAL:-0}" == "1" ]]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
# This is a generated bundle; start clean so removed dependencies cannot leave stale resources.
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Linvell" "$APP/Contents/MacOS/Linvell"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Brand/Linvell.png "$APP/Contents/Resources/Linvell.png"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
if [[ -f Resources/ThirdPartyNotices.txt ]]; then cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/ThirdPartyNotices.txt"; fi
for resource in "$BIN_DIR"/*.bundle; do
  [[ -d "$resource" ]] && ditto "$resource" "$APP/Contents/Resources/$(basename "$resource")"
done
codesign --force --sign - "$APP"
case "$MODE" in
  --build-only) printf '%s\n' "$APP" ;;
  run) open -n "$APP" ;;
  --demo) open -n "$APP" --args --demo "$ROOT_DIR/Samples/Welcome.swift" ;;
  --verify) open -n "$APP"; sleep 1; pgrep -x Linvell >/dev/null ;;
  --debug) lldb -- "$APP/Contents/MacOS/Linvell" ;;
  --logs|--telemetry) open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "Linvell"' ;;
  *) echo "usage: $0 [run|--build-only|--demo|--verify|--debug|--logs]" >&2; exit 2 ;;
esac
