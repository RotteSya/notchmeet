#!/bin/sh
# Build a Developer-ID-signed, Apple-NOTARIZED, stapled .dmg so other people can install and
# run notchmeet with NO Gatekeeper prompt. This is the real distribution build — distinct from
# scripts/dev-run.sh (dev-only, Apple Development / ad-hoc, blocked on other Macs).
#
# One-time setup (secrets stay in your Keychain, never in the repo):
#   1. Create an app-specific password at https://appleid.apple.com → Sign-In and Security.
#   2. Store a notary credential profile:
#        xcrun notarytool store-credentials notchmeet-notary \
#          --apple-id "<your-apple-id-email>" --team-id TZ2T95MG29 --password "<app-specific-pw>"
#   (Alternatively use an App Store Connect API key: --key / --key-id / --issuer.)
#
# Then: scripts/release.sh   →   .build/notchmeet-<version>.dmg (notarized + stapled)
set -e
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: SHE LINGZHAO (TZ2T95MG29)"
PROFILE="${NOTARY_PROFILE:-notchmeet-notary}"
ENTITLEMENTS="Resources/notchmeet.entitlements"

if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "ERROR: '$IDENTITY' not in the keychain. A Developer ID Application cert is required."; exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "ERROR: notary profile '$PROFILE' not found. Run the 'store-credentials' command in this"
    echo "       script's header first (needs your Apple ID + an app-specific password)."; exit 1
fi

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP=".build/notchmeet.app"
DMG=".build/notchmeet-${VER}.dmg"

# 1. Build + assemble the .app from the RELEASE binary.
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/notchmeet" "$APP/Contents/MacOS/notchmeet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIcon.png "$APP/Contents/Resources/AppIcon.png"

# 2. Sign with Developer ID + hardened runtime (required for notarization) + secure timestamp
#    + the audio-input entitlement (so the hardened app can still capture call-app audio).
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 3. Notarize the app (zip it for submission) and staple the ticket so it works offline.
echo "Notarizing the app (Apple scan, a few minutes)…"
ZIP=".build/notchmeet-app.zip"; rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# 4. Build the drag-install .dmg from the stapled app, sign it, notarize + staple it too.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/notchmeet.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "notchmeet ${VER}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "Notarizing the dmg…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# 5. Verify Gatekeeper will accept it with no prompt.
echo "=== verification ==="
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true
codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "Built + notarized: $DMG"
echo "Publish:  gh release create \"v${VER}\" \"$DMG\" --title \"notchmeet v${VER}\" --notes-file <notes.md>"
