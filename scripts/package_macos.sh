#!/usr/bin/env bash
# Build the macOS packages (.dmg and .pkg) from a finished Flutter bundle.
#
#   scripts/package_macos.sh <app-bundle> <version> <output-dir>
#
# <app-bundle>  the built app, e.g. build/macos/Build/Products/Release/imagyn.app
#
# Only macOS can run this: iconutil, pkgbuild and hdiutil are part of the
# system. Nothing is signed with a Developer ID, so a downloaded copy has to be
# opened through Gatekeeper by hand; the release notes say so. The .icns is
# assembled from platform/icons/png, so run scripts/make_icons.sh first.
set -euo pipefail

APP=${1:?usage: package_macos.sh <app-bundle> <version> <output-dir>}
VERSION=${2:?usage: package_macos.sh <app-bundle> <version> <output-dir>}
OUT=${3:?usage: package_macos.sh <app-bundle> <version> <output-dir>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

BUNDLE_ID=app.imagyn
[ -d "$APP" ] || { echo "package_macos: no app bundle at $APP" >&2; exit 1; }
[ -f "$ROOT/LICENSE" ] || { echo "package_macos: LICENSE is missing" >&2; exit 1; }
for size in 16 32 64 128 256 512 1024; do
  [ -f "$ROOT/platform/icons/png/$size.png" ] ||
    { echo "package_macos: platform/icons/png/$size.png is missing; run scripts/make_icons.sh" >&2; exit 1; }
done

mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The app is copied out of the build directory before it is touched: renaming it
# to Imagyn.app and swapping the icon changes the bundle, so the build output
# stays as Flutter left it.
APP_DIR="$WORK/Imagyn.app"
cp -R "$APP" "$APP_DIR"

# --- the .icns ----------------------------------------------------------------
mkdir -p "$WORK/Imagyn.iconset"
cp "$ROOT/platform/icons/png/16.png"   "$WORK/Imagyn.iconset/icon_16x16.png"
cp "$ROOT/platform/icons/png/32.png"   "$WORK/Imagyn.iconset/icon_16x16@2x.png"
cp "$ROOT/platform/icons/png/32.png"   "$WORK/Imagyn.iconset/icon_32x32.png"
cp "$ROOT/platform/icons/png/64.png"   "$WORK/Imagyn.iconset/icon_32x32@2x.png"
cp "$ROOT/platform/icons/png/128.png"  "$WORK/Imagyn.iconset/icon_128x128.png"
cp "$ROOT/platform/icons/png/256.png"  "$WORK/Imagyn.iconset/icon_128x128@2x.png"
cp "$ROOT/platform/icons/png/256.png"  "$WORK/Imagyn.iconset/icon_256x256.png"
cp "$ROOT/platform/icons/png/512.png"  "$WORK/Imagyn.iconset/icon_256x256@2x.png"
cp "$ROOT/platform/icons/png/512.png"  "$WORK/Imagyn.iconset/icon_512x512.png"
cp "$ROOT/platform/icons/png/1024.png" "$WORK/Imagyn.iconset/icon_512x512@2x.png"
iconutil -c icns "$WORK/Imagyn.iconset" -o "$WORK/AppIcon.icns"
cp "$WORK/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Flutter's template names the bundle after the project, so Finder would show
# "imagyn". PlistBuddy is part of the system on every macOS runner.
PLIST="$APP_DIR/Contents/Info.plist"
for key in CFBundleName CFBundleDisplayName; do
  /usr/libexec/PlistBuddy -c "Set :$key Imagyn" "$PLIST" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :$key string Imagyn" "$PLIST"
done

# Editing the bundle invalidated the ad-hoc signature Flutter applied, and macOS
# refuses to launch an app whose signature no longer matches. Re-sign ad-hoc,
# carrying over the entitlements the original signature had (app sandbox,
# network client, keychain access) — signing without them would silently drop
# the sandbox. They are read from the untouched build output, not from the copy
# that has already been edited. This says nothing about notarisation, which
# would need a Developer ID.
codesign -d --entitlements :- "$APP" > "$WORK/entitlements.plist" 2>/dev/null || true
if [ -s "$WORK/entitlements.plist" ]; then
  codesign --force --sign - --entitlements "$WORK/entitlements.plist" "$APP_DIR"
else
  codesign --force --sign - "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"

# --- .pkg ---------------------------------------------------------------------
pkgbuild --component "$APP_DIR" --install-location /Applications \
  --identifier "$BUNDLE_ID" --version "$VERSION" \
  "$OUT/imagyn-$VERSION-macos.pkg"
echo "package_macos: imagyn-$VERSION-macos.pkg"

# --- .dmg ---------------------------------------------------------------------
mkdir -p "$WORK/dmg"
cp -R "$APP_DIR" "$WORK/dmg/Imagyn.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "Imagyn $VERSION" -srcfolder "$WORK/dmg" -ov \
  -format UDZO "$OUT/imagyn-$VERSION-macos.dmg" >/dev/null
echo "package_macos: imagyn-$VERSION-macos.dmg"
