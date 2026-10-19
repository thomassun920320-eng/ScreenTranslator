#!/bin/bash
# 編譯 ScreenTranslator 並打包成 .app 與 .dmg
# 用法：./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ScreenTranslator"
VERSION="1.1.3"
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

echo "▸ 簽署（固定的本機憑證）"
# ad-hoc 簽章的身分是程式雜湊值，每次編譯都會變，macOS 就會把它當成新 App 而要求重新授權。
# 改用一張固定的自簽憑證，存在獨立的鑰匙圈檔案（不動登入鑰匙圈），權限就能在更新後保留。
SIGN_DIR="$HOME/Library/Application Support/ScreenTranslator-Signing"
SIGN_KC="$SIGN_DIR/signing.keychain-db"
SIGN_NAME="ScreenTranslator Local Signing"
if [ ! -f "$SIGN_KC" ]; then
  echo "  第一次編譯：建立簽章憑證於 $SIGN_DIR"
  mkdir -p "$SIGN_DIR" && chmod 700 "$SIGN_DIR"
  openssl rand -hex 24 > "$SIGN_DIR/keychain-password" && chmod 600 "$SIGN_DIR/keychain-password"
  TMPC="$(mktemp -d)"
  printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$SIGN_NAME" > "$TMPC/cert.cnf"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMPC/key.pem" -out "$TMPC/cert.pem" -days 3650 -config "$TMPC/cert.cnf" 2>/dev/null
  P12PASS="$(openssl rand -hex 12)"
  openssl pkcs12 -export -legacy -inkey "$TMPC/key.pem" -in "$TMPC/cert.pem" -out "$TMPC/id.p12" -passout "pass:$P12PASS" 2>/dev/null \
    || openssl pkcs12 -export -inkey "$TMPC/key.pem" -in "$TMPC/cert.pem" -out "$TMPC/id.p12" -passout "pass:$P12PASS"
  security create-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_KC"
  security set-keychain-settings "$SIGN_KC"
  security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_KC"
  security import "$TMPC/id.p12" -k "$SIGN_KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_KC" >/dev/null 2>&1 || true
  rm -rf "$TMPC"
fi
security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_KC"
xattr -cr "$APP"
codesign --force --deep --keychain "$SIGN_KC" --sign "$SIGN_NAME" --identifier "$BUNDLE_ID" "$APP"
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
