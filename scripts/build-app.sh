#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ""|--install) ;; *) echo 'Usage: scripts/build-app.sh [--install]' >&2; exit 2;; esac
SWIFT_BUILD=(swift build -c release)
# Opt-in for environments that prohibit SwiftPM's nested sandbox. This does not
# change the host's sandbox/permissions or the built application's behaviour.
if [[ "${BACKTRACK_DISABLE_SPM_SANDBOX:-0}" == 1 ]]; then SWIFT_BUILD+=(--disable-sandbox); fi
"${SWIFT_BUILD[@]}"
BIN="$("${SWIFT_BUILD[@]}" --show-bin-path)/Backtrack"
APP="$PWD/dist/Backtrack.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Ship the existing icon as a normal source asset. Rebuilding the application
# must not depend on iconutil's graphical services being available on the host.
# scripts/render-icon.swift remains the source for intentional icon regeneration.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Backtrack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/semantic_search.py "$APP/Contents/Resources/"
cp Resources/index_sessions.py Resources/history_cache.py "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/__pycache__"
codesign --force --sign - --entitlements Resources/Backtrack.entitlements "$APP"
codesign --verify --deep --strict "$APP"
if [[ "${1:-}" == --install ]]; then
    DEST="/Applications/Backtrack.app"
    if pgrep -f '^/Applications/Backtrack.app/Contents/MacOS/Backtrack( |$)' >/dev/null; then
        echo 'Quit Backtrack before reinstalling. Nothing replaced.' >&2; exit 1
    else
        PROCESS_CHECK=$?
        if [[ "$PROCESS_CHECK" != 1 ]]; then
            echo 'Cannot confirm Backtrack is closed. Nothing replaced.' >&2; exit 1
        fi
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
