#!/bin/bash
# 編譯 ScreenTranslator 並打包成 .app 與 .dmg
# 用法：./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ScreenTranslator"
VERSION="1.1.1"
BUNDLE_ID="com.sunchangxin.screentranslator"
OUT="build"
# 在暫存資料夾組裝：Documents 若由 iCloud 同步，會自動加上延伸屬性導致簽章失效
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/$APP_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

rm -rf "$OUT" && mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 編譯 (arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos14.0" Sources/main.swift -o "$BUILD/$APP_NAME-$arch"
done
lipo -create "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
rm "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"

echo "▸ 產生圖示"
ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
[ -f assets/icon_1024.png ] || swift scripts/make_icon.swift assets/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>ScreenTranslator</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>需要擷取目前視窗畫面以辨識並翻譯文字。</string>
</dict>
</plist>
EOF

echo "▸ 簽署 (ad-hoc)"
xattr -cr "$APP"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ 製作 DMG"
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW "$BUILD/rw.dmg" >/dev/null
# 設定掛載磁碟的自訂圖示
MOUNT=$(hdiutil attach -nobrowse -noautoopen "$BUILD/rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
SetFile -a C "$MOUNT" 2>/dev/null || true
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$BUILD/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$BUILD/final.dmg" >/dev/null
cp "$BUILD/final.dmg" "$DMG"

echo "✓ 完成：$DMG"
