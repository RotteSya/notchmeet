#!/bin/sh
# Build a signed, drag-install .dmg for a release (wraps the .app from bundle.sh).
# 版本号从 Resources/Info.plist 的 CFBundleShortVersionString 读取（单一来源）。
# Apple Development 签名 only —— 对外无障碍分发需 Developer ID + 公证（PLAN §11）。
set -e
cd "$(dirname "$0")/.."

# 先产出新鲜的签名 .app（swift build -c release + 组装 + codesign）。
scripts/bundle.sh

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP=".build/notchmeet.app"
DMG=".build/notchmeet-${VER}.dmg"

# 拖装布局：App + /Applications 软链。
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/notchmeet.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "notchmeet ${VER}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 用 bundle.sh 同款稳定身份签 dmg；没装则回退 ad-hoc。
IDENTITY="Apple Development: SHE LINGZHAO (GKA8C557H7)"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$DMG"
else
    codesign --force --sign - "$DMG"
fi

hdiutil verify "$DMG" >/dev/null
echo "Built $DMG"
echo "Release:  gh release create \"v${VER}\" \"$DMG\" --title \"notchmeet v${VER}\" --notes-file <notes.md>"
