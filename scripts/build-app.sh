#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ""|--install) ;; *) echo 'Usage: scripts/build-app.sh [--install]' >&2; exit 2;; esac
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Backtrack"
APP="$PWD/dist/Backtrack.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build/AppIcon.iconset
swift scripts/render-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Backtrack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/semantic_search.py "$APP/Contents/Resources/"
cp Resources/index_sessions.py "$APP/Contents/Resources/"
codesign --force --sign - --entitlements Resources/Backtrack.entitlements "$APP"
codesign --verify --deep --strict "$APP"
if [[ "${1:-}" == --install ]]; then
    DEST="/Applications/Backtrack.app"
    if pgrep -f '^/Applications/Backtrack.app/Contents/MacOS/Backtrack( |$)' >/dev/null; then
        echo 'Quit Backtrack before reinstalling. Nothing replaced.' >&2; exit 1
    fi
    if [[ -L "$DEST" ]]; then echo 'Refusing to replace a symlink.' >&2; exit 1; fi
    if [[ -e "$DEST" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")" != com.jacobsapps.Backtrack ]]; then
        echo 'Destination is another app. Nothing replaced.' >&2; exit 1
    fi
    STAGING="$(mktemp -d /Applications/.backtrack-install.XXXXXX)"
    cleanup() {
        if [[ -d "$STAGING/previous.app" && ! -e "$DEST" ]]; then mv "$STAGING/previous.app" "$DEST"; fi
        rm -rf "$STAGING"
    }
    trap cleanup EXIT
    ditto "$APP" "$STAGING/Backtrack.app"
    codesign --verify --deep --strict "$STAGING/Backtrack.app"
    if [[ -e "$DEST" ]]; then mv "$DEST" "$STAGING/previous.app"; fi
    mv "$STAGING/Backtrack.app" "$DEST"
    echo "Installed (not launched): $DEST"
fi
echo "Built: $APP"
