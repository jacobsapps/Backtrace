#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ""|--install) ;; *) echo 'Usage: scripts/build-app.sh [--install]' >&2; exit 2;; esac
SWIFT_BUILD=(swift build -c release)
# Optional workaround for host build-engine issues; applied to build and bin lookup.
if [[ -n "${BACKTRACE_BUILD_SYSTEM:-}" ]]; then SWIFT_BUILD+=(--build-system "$BACKTRACE_BUILD_SYSTEM"); fi
# Opt-in for environments that prohibit SwiftPM's nested sandbox. This does not
# change the host's sandbox/permissions or the built application's behaviour.
if [[ "${BACKTRACE_DISABLE_SPM_SANDBOX:-${BACKTRACK_DISABLE_SPM_SANDBOX:-0}}" == 1 ]]; then SWIFT_BUILD+=(--disable-sandbox); fi
"${SWIFT_BUILD[@]}"
BIN="$("${SWIFT_BUILD[@]}" --show-bin-path)/Backtrace"
APP="$PWD/dist/Backtrace.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Ship the existing icon as a normal source asset. Rebuilding the application
# must not depend on iconutil's graphical services being available on the host.
# scripts/render-icon.swift remains the source for intentional icon regeneration.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/BrandMark.pdf Resources/MenuBarMark.pdf "$APP/Contents/Resources/"
cp "$BIN" "$APP/Contents/MacOS/Backtrace"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/semantic_search.py "$APP/Contents/Resources/"
cp Resources/index_sessions.py Resources/history_cache.py "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/__pycache__"
codesign --force --sign - --entitlements Resources/Backtrace.entitlements "$APP"
codesign --verify --deep --strict "$APP"
# Preserve a fresh bundle timestamp through ditto so macOS notices icon updates.
touch "$APP"
if [[ "${1:-}" == --install ]]; then
    DEST="/Applications/Backtrace.app"
    LEGACY="/Applications/Backtrack.app"
    if pgrep -f '^/Applications/(Backtrace|Backtrack).app/Contents/MacOS/(Backtrace|Backtrack)( |$)' >/dev/null; then
        echo 'Quit Backtrace (or Backtrack) before reinstalling. Nothing replaced.' >&2; exit 1
    else
        PROCESS_CHECK=$?
        if [[ "$PROCESS_CHECK" != 1 ]]; then
            echo 'Cannot confirm Backtrace is closed. Nothing replaced.' >&2; exit 1
        fi
    fi
    for CANDIDATE in "$DEST" "$LEGACY"; do
        if [[ -L "$CANDIDATE" ]]; then echo 'Refusing to replace a symlink.' >&2; exit 1; fi
        if [[ -e "$CANDIDATE" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CANDIDATE/Contents/Info.plist")" != com.jacobsapps.Backtrack ]]; then
            echo 'Destination is another app. Nothing replaced.' >&2; exit 1
        fi
    done
    STAGING="$(mktemp -d /Applications/.backtrace-install.XXXXXX)"
    INSTALLED=0
    cleanup() {
        if [[ "$INSTALLED" == 0 ]]; then
            if [[ -d "$STAGING/previous.app" && ! -e "$DEST" ]]; then mv "$STAGING/previous.app" "$DEST"; fi
            if [[ -d "$STAGING/legacy.app" && ! -e "$LEGACY" ]]; then mv "$STAGING/legacy.app" "$LEGACY"; fi
        fi
        rm -rf "$STAGING"
    }
    trap cleanup EXIT
    ditto "$APP" "$STAGING/Backtrace.app"
    codesign --verify --deep --strict "$STAGING/Backtrace.app"
    if [[ -e "$DEST" ]]; then mv "$DEST" "$STAGING/previous.app"; fi
    if [[ -e "$LEGACY" ]]; then mv "$LEGACY" "$STAGING/legacy.app"; fi
    mv "$STAGING/Backtrace.app" "$DEST"
    INSTALLED=1
    echo "Installed (not launched): $DEST"
fi
echo "Built: $APP"
