#!/bin/zsh
# Publie Lanes : build release, bundle, signature Developer ID (runtime durci,
# horodatage), notarisation Apple, ticket agrafé, zip + DMG, release GitHub.
#
#   Scripts/release.sh 1.0            # tout
#   NOTARIZE=0 Scripts/release.sh 1.0 # signé, sans aller-retour Apple
#   PUBLISH=0 Scripts/release.sh 1.0  # sans créer la release GitHub
#
# Sur la machine : l'identité « Developer ID Application » dans le Trousseau,
# le profil notarytool (NOTARY_PROFILE, « souffleuse » par défaut), gh connecté.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release.sh <version>}"
NOTARIZE="${NOTARIZE:-1}"
PUBLISH="${PUBLISH:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-souffleuse}"
IDENTITY="${IDENTITY:-Developer ID Application}"
REPO="${REPO:-menufactory43/lanes}"
OUT="build/release"
APP="$OUT/Lanes.app"
ZIP="$OUT/Lanes-$VERSION.zip"
DMG="$OUT/Lanes-$VERSION.dmg"
BUILD_NUMBER="$(git rev-list --count HEAD)"

etape() { printf '\n▸ %s\n' "$*"; }

etape "Build release ($VERSION, build $BUILD_NUMBER)"
swift build -c release --product Lanes 2>&1 | grep -E "error|warning:" || true
BIN=".build/release/Lanes"
[[ -x "$BIN" ]] || { echo "✗ binaire introuvable"; exit 1; }

etape "Bundle"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lanes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] || swift Scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
strip -x "$APP/Contents/MacOS/Lanes"
otool -L "$APP/Contents/MacOS/Lanes" | grep -vE "/System/|/usr/lib/" | tail -n +2 | grep . && { echo "✗ dépendance hors système"; exit 1; } || true

etape "Signature Developer ID (runtime durci, horodatage)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier app.lanes.dashboard "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "^Authority=Developer ID Application" || { echo "✗ pas de signature Developer ID"; exit 1; }

if [[ "$NOTARIZE" == 1 ]]; then
  etape "Notarisation de l'app (profil « $NOTARY_PROFILE »)"
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait | grep -E 'id:|status:' | tail -2
  rm -f "$OUT/notarize.zip"
  xcrun stapler staple "$APP" | tail -1
fi

etape "Zip"
ditto -c -k --keepParent "$APP" "$ZIP"

etape "DMG"
STAGING="$OUT/dmg"; rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"; ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Lanes" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [[ "$NOTARIZE" == 1 ]]; then
  etape "Notarisation du DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | grep -E 'id:|status:' | tail -2
  xcrun stapler staple "$DMG" | tail -1
  etape "Gatekeeper"
  spctl -a -vvv -t install "$DMG" 2>&1 | grep -E 'accepted|rejected|source='
  spctl -a -vvv -t exec "$APP" 2>&1 | grep -E 'accepted|rejected|source='
fi

shasum -a 256 "$ZIP" "$DMG" | tee "$OUT/SHA256SUMS.txt"

if [[ "$PUBLISH" == 1 ]]; then
  etape "Release GitHub $REPO v$VERSION"
  git tag -f "v$VERSION" >/dev/null
  git push -q origin "v$VERSION" --force
  gh release create "v$VERSION" "$ZIP" "$DMG" "$OUT/SHA256SUMS.txt" --repo "$REPO" \
    --title "Lanes $VERSION" --generate-notes
fi
echo; echo "✅ $ZIP · $DMG"
