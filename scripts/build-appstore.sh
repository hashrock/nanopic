#!/bin/bash
# App Store 用のビルドを作る: エージェント連携（MCP）を外した build/appstore/Nanopic.app
#
#   ./scripts/build-appstore.sh
#   SANDBOX=1 ./scripts/build-appstore.sh   # App Sandbox を付けて ad-hoc 署名する（手元で Sandbox の中の動作を確かめる用）
#
# 配布用の署名と .pkg 化は scripts/package-appstore.sh（このスクリプトを呼んでから署名する）
#
# MCP はコンパイルの段階で外す（Package.swift の NANOPIC_APPSTORE）。実行時に隠しているのではないことを、
# できたバイナリに MCP の文字列・シンボルが残っていないことで確かめる。
# App Store に出すのに要る Info.plist の項目・プライバシーマニフェスト・アイコン・entitlement も確かめる。
# ここでは配布用の署名・App Store Connect への送信はしない（Apple とは通信しない）。
set -euo pipefail
cd "$(dirname "$0")/.."

NANOPIC_APPSTORE=1 ./scripts/build-app.sh
BIN=build/appstore/Nanopic.app/Contents/MacOS/Nanopic

# memcpy は "mcp" を含むので除く
LEFT=$( { strings -a "$BIN"; nm "$BIN" 2>/dev/null; } | grep -iE 'mcp|NanopicAgent|AgentTool' | grep -v memcpy || true)
if [ -n "$LEFT" ]; then
    echo "App Store 用のバイナリにエージェント連携（MCP）が残っています:" >&2
    echo "$LEFT" | head -20 >&2
    exit 1
fi
# 待ち受け（NWListener）も入っていないこと
if nm "$BIN" 2>/dev/null | grep -q 'NWListener'; then
    echo "App Store 用のバイナリに NWListener（待ち受け）が残っています" >&2
    exit 1
fi
if otool -L "$BIN" | grep -q 'Network.framework'; then
    echo "App Store 用のバイナリが Network.framework をリンクしています" >&2
    exit 1
fi
# 訳の表にも入っていないこと（エージェント連携の画面の訳は Agent の表に分けてあり、App Store 用には入れない）
RES=build/appstore/Nanopic.app/Contents/Resources
if [ -e "$RES/en.lproj/Agent.strings" ] || [ -e "$RES/ja.lproj/Agent.strings" ]; then
    echo "App Store 用のアプリにエージェント連携の訳（Agent.strings）が入っています" >&2
    exit 1
fi
LEFT=$(for f in "$RES"/*.lproj/*; do plutil -convert xml1 -o - "$f" 2>/dev/null || cat "$f"; done | grep -iE 'mcp|エージェント|agent' || true)
if [ -n "$LEFT" ]; then
    echo "App Store 用の訳の表にエージェント連携（MCP）の文言が残っています:" >&2
    echo "$LEFT" | head -20 >&2
    exit 1
fi
echo "OK: MCP の文字列・シンボル、待ち受けは入っていません（${BIN}、訳の表）"

# --- App Store に出すのに要るもの ---
APP=build/appstore/Nanopic.app
PLIST="$APP/Contents/Info.plist"
fail() { echo "NG: $*" >&2; exit 1; }
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

# Xcode で作ったアプリに入る項目（どの Xcode・SDK で作ったか）。App Store Connect の検査が見るので入れておく
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
SDK_BUILD=$(xcrun --sdk macosx --show-sdk-build-version)
XCODE_VERSION=$(xcodebuild -version | awk '/^Xcode/ { split($2, v, "."); printf "%02d%d%d", v[1], v[2] + 0, v[3] + 0 }')
XCODE_BUILD=$(xcodebuild -version | awk '/^Build version/ { print $3 }')
add() { /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"; }
add BuildMachineOSBuild "$(sw_vers -buildVersion)"
add DTCompiler com.apple.compilers.llvm.clang.1_0
add DTPlatformName macosx
add DTPlatformVersion "$SDK_VERSION"
add DTPlatformBuild "$SDK_BUILD"
add DTSDKName "macosx$SDK_VERSION"
add DTSDKBuild "$SDK_BUILD"
add DTXcode "$XCODE_VERSION"
add DTXcodeBuild "$XCODE_BUILD"
plutil -lint "$PLIST" >/dev/null || fail "Info.plist が壊れています"

[ "$(pb CFBundleIdentifier)" = "com.hashrock.nanopic" ] || fail "CFBundleIdentifier が com.hashrock.nanopic ではありません"
[ -n "$(pb LSApplicationCategoryType)" ] || fail "LSApplicationCategoryType がありません"
[ "$(pb ITSAppUsesNonExemptEncryption)" = "false" ] || fail "ITSAppUsesNonExemptEncryption が false ではありません"
[ -n "$(pb CFBundleShortVersionString)" ] && [ -n "$(pb CFBundleVersion)" ] || fail "版がありません"
[ -n "$(pb LSMinimumSystemVersion)" ] || fail "LSMinimumSystemVersion がありません"
plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null || fail "PrivacyInfo.xcprivacy がありません"
# 表示言語: 日本語・英語（App Store の「言語」に出る）。Info.plist の申告と、Resources の .lproj の両方
[ "$(pb CFBundleDevelopmentRegion)" = "ja" ] || fail "CFBundleDevelopmentRegion が ja ではありません"
[ "$(pb CFBundleLocalizations:0) $(pb CFBundleLocalizations:1)" = "ja en" ] || fail "CFBundleLocalizations が ja・en ではありません"
for TABLE in Localizable Names; do
    plutil -lint "$APP/Contents/Resources/en.lproj/$TABLE.strings" >/dev/null || fail "en.lproj/$TABLE.strings がありません"
    [ -f "$APP/Contents/Resources/ja.lproj/$TABLE.strings" ] || fail "ja.lproj/$TABLE.strings がありません"
done
# アイコンは icns に 512pt の @2x（1024px）まで入っていること
ICONSET=$(mktemp -d)/AppIcon.iconset
iconutil -c iconset "$APP/Contents/Resources/AppIcon.icns" -o "$ICONSET" || fail "AppIcon.icns を読めません"
[ -f "$ICONSET/icon_512x512@2x.png" ] && [ -f "$ICONSET/icon_512x512.png" ] || fail "AppIcon.icns に 512pt（@1x・@2x）がありません"
rm -rf "$(dirname "$ICONSET")"
ARCHS=$(lipo -archs "$BIN")
case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) ;; *) fail "ユニバーサルではありません（${ARCHS}）" ;; esac
# entitlement: Sandbox あり、通信なし、余計な例外なし
ENT=scripts/appstore.entitlements
plutil -lint "$ENT" >/dev/null || fail "entitlements が壊れています"
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENT")" = "true" ] || fail "app-sandbox がありません"
if grep -qE 'com\.apple\.security\.(network|temporary-exception|cs\.)' "$ENT"; then fail "entitlements に通信か例外が入っています"; fi
echo "OK: Info.plist・PrivacyInfo・アイコン・表示言語（ja・en）・entitlements（$(pb CFBundleShortVersionString) / $(pb CFBundleVersion)、${ARCHS}）"

if [ "${SANDBOX:-}" = "1" ]; then
    codesign --force --sign - --entitlements scripts/appstore.entitlements build/appstore/Nanopic.app
    codesign -d --entitlements - --xml build/appstore/Nanopic.app 2>/dev/null | grep -q 'com.apple.security.app-sandbox' \
        || fail "署名に app-sandbox が入っていません"
    echo "App Sandbox を付けて ad-hoc 署名しました（配布用の署名ではありません）"
fi
