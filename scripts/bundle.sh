#!/bin/sh
# Assemble a runnable .app bundle (stable Bundle ID for TCC) and sign it.
# Dev only — real distribution needs Developer ID signing + notarization (PLAN §11).
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP=".build/notchmeet.app"
BIN=".build/release/notchmeet"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/notchmeet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIcon.png "$APP/Contents/Resources/AppIcon.png"   # onboarding shows the PNG

# Prefer a stable signing identity (so Keychain/TCC grants persist across
# rebuilds); fall back to ad-hoc if it isn't installed.
IDENTITY="Apple Development: SHE LINGZHAO (GKA8C557H7)"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || true
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built $APP"
echo "Run:  open \"$APP\"    (or: \"$APP/Contents/MacOS/notchmeet\" for logs)"
