#!/bin/bash
# リリースビルドして build/Nanopic.app を作る
#
#   ./scripts/build-app.sh                      # ふだんのビルド（Developer ID 版。エージェント連携あり）
#   NANOPIC_APPSTORE=1 ./scripts/build-app.sh   # App Store 用（エージェント連携なし）→ build/appstore/Nanopic.app
#
# App Store 用は scripts/build-appstore.sh から呼ぶ（MCP が入っていないことも確かめる）
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${NANOPIC_APPSTORE:-}" = "1" ]; then
    # ふだんのビルドと中間ファイルが混ざらないよう、ビルド先を分ける
    BUILD=(swift build -c release --scratch-path .build-appstore)
    APP=build/appstore/Nanopic.app
else
    unset NANOPIC_APPSTORE
    BUILD=(swift build -c release)
    APP=build/Nanopic.app
fi
"${BUILD[@]}"
BIN="$("${BUILD[@]}" --show-bin-path)/Nanopic"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nanopic"
swift scripts/make-icon.swift Resources/AppIcon.svg "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Nanopic</string>
    <key>CFBundleDisplayName</key><string>Nanopic</string>
    <key>CFBundleIdentifier</key><string>dev.hashrock.nanopic</string>
    <key>CFBundleExecutable</key><string>Nanopic</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.10.0</string>
    <key>CFBundleVersion</key><string>10</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Photoshop Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.adobe.photoshop-image</string></array>
        </dict>
        <!-- サイドカー（作品.psd の隣の 作品.nanopic）。App Sandbox の中で隣のファイルを読み書きするための「関連ファイル」の宣言。
             Role が Editor でないと書けない。LSHandlerRank を None にして、Finder からこのアプリで開く候補にはしない -->
        <dict>
            <key>CFBundleTypeName</key><string>Nanopic Sidecar</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>CFBundleTypeExtensions</key><array><string>nanopic</string></array>
            <key>NSIsRelatedItemType</key><true/>
        </dict>
    </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
