#!/bin/sh
# Dev loop: rebuild the .app bundle, stop the running instance, relaunch.
# Use after code changes — the bundle runs the RELEASE binary, which `swift build`
# alone doesn't refresh, so the menu-bar app keeps showing old code until repackaged.
# Pass -l/--logs to run in the foreground and stream NSLog instead of detaching.
set -e
cd "$(dirname "$0")/.."

# 1. Rebuild + sign the bundle (release build, stable identity — see bundle.sh).
sh scripts/bundle.sh

APP=".build/notchmeet.app"
BIN="$APP/Contents/MacOS/notchmeet"

# 2. Stop any running instance (ignore "no process matched").
pkill -f "notchmeet.app/Contents/MacOS/notchmeet" 2>/dev/null || true
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
