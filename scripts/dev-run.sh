#!/bin/sh
# Dev loop: rebuild the .app bundle, stop the running instance, relaunch.
# Use after code changes — the bundle runs the RELEASE binary, which `swift build`
# alone doesn't refresh, so the menu-bar app keeps showing old code until repackaged.
# Pass -l/--logs to run in the foreground and stream NSLog instead of detaching.
#
# Dev-only packaging: Apple Development (or ad-hoc) signature — fine on THIS Mac, but
# blocked by Gatekeeper on others. For a distributable build use scripts/release.sh
# (Developer ID + notarization).
set -e
cd "$(dirname "$0")/.."

APP=".build/NotchMeet.app"
BIN="$APP/Contents/MacOS/NotchMeet"

# 1. Rebuild + assemble the .app from the RELEASE binary, with a stable Bundle ID so
#    Keychain/TCC grants persist across rebuilds. System-audio capture only works from
#    a real .app bundle, which `swift build`/`swift run` alone don't produce.
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/notchmeet" "$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIcon.png "$APP/Contents/Resources/AppIcon.png"   # onboarding shows the PNG

# Prefer a stable signing identity (so Keychain/TCC grants persist across rebuilds);
# fall back to ad-hoc if it isn't installed.
IDENTITY="Apple Development: SHE LINGZHAO (GKA8C557H7)"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || true
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

# 2. Stop any running instance (ignore "no process matched").
pkill -f "NotchMeet.app/Contents/MacOS/NotchMeet" 2>/dev/null || true
sleep 1

# 3. Relaunch.
case "$1" in
  -l|--logs)
    echo "Running in foreground (Ctrl-C to stop) — NSLog streams below:"
    exec "$BIN"
    ;;
  *)
    open "$APP"
    echo "Relaunched $APP"
    ;;
esac
