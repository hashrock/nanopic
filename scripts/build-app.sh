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
    # Intel の Mac でも動くよう、App Store 用はユニバーサルにする（直接配布版はこれまでどおり、ビルドした Mac の向きだけ）
    BUILD=(swift build -c release --scratch-path .build-appstore --arch arm64 --arch x86_64)
    APP=build/appstore/Nanopic.app
    # エージェント連携の画面の訳（Agent）は入れない
    TABLES=(Localizable Names)
else
    unset NANOPIC_APPSTORE
    BUILD=(swift build -c release)
    APP=build/Nanopic.app
    TABLES=(Localizable Names Agent)
fi
"${BUILD[@]}"
BIN="$("${BUILD[@]}" --show-bin-path)/Nanopic"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nanopic"
swift scripts/make-icon.swift Resources/AppIcon.svg "$APP/Contents/Resources/AppIcon.icns"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
# 表示言語（日本語・英語）。訳を .lproj にして入れる
./scripts/compile-localization.sh "$APP/Contents/Resources" "${TABLES[@]}"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Nanopic</string>
    <key>CFBundleDisplayName</key><string>Nanopic</string>
    <key>CFBundleIdentifier</key><string>com.hashrock.nanopic</string>
    <key>CFBundleExecutable</key><string>Nanopic</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <!-- 表示言語。Resources の ja.lproj・en.lproj と合わせる（App Store の「言語」に出る） -->
    <key>CFBundleLocalizations</key><array><string>ja</string><string>en</string></array>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>CFBundleShortVersionString</key><string>0.11.0</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 hashrock</string>
    <!-- 暗号は使っていない（App Store Connect の輸出コンプライアンスの質問を省く） -->
    <key>ITSAppUsesNonExemptEncryption</key><false/>
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
