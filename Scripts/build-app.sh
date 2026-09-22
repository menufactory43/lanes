#!/bin/zsh
# Construit Lanes.app en release et l'installe dans ~/Applications.
# Usage : Scripts/build-app.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug
swift build -c $CONFIG --product Lanes 2>&1 | grep -E "error|warning:|Compiling|Build" | grep -vE "^\[" || true
BIN=".build/$CONFIG/Lanes"
[[ -x "$BIN" ]] || { echo "binaire introuvable : $BIN"; exit 1; }
APP="build/Lanes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lanes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then swift Scripts/make-icon.swift Resources/AppIcon.icns; fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Localisations : en (langue de développement) et fr, lues dans Bundle.main.
for lp in Resources/*.lproj; do cp -R "$lp" "$APP/Contents/Resources/"; done
echo -n "APPL????" > "$APP/Contents/PkgInfo"
strip -x "$APP/Contents/MacOS/Lanes" 2>/dev/null || true
codesign --force --sign - --identifier app.lanes.dashboard "$APP" 2>&1 | grep -v "replacing existing signature" || true
mkdir -p ~/Applications
rm -rf ~/Applications/Lanes.app
cp -R "$APP" ~/Applications/Lanes.app
echo "→ ~/Applications/Lanes.app ($(du -sh "$APP" | cut -f1), $CONFIG)"
otool -L "$APP/Contents/MacOS/Lanes" | grep -vE "/System/|/usr/lib/" | tail -n +2 || true
