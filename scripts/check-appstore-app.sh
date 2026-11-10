#!/bin/bash
# App Store 用の Nanopic.app を検査する（作りはしない。Apple とも通信しない）
#
#   ./scripts/check-appstore-app.sh <Nanopic.app>                  # 中身だけ（MCP なし、Info.plist、言語、アイコンなど）
#   ./scripts/check-appstore-app.sh <Nanopic.app> --signed         # ＋署名に Sandbox が入り、通信がないこと（ad-hoc 署名でもよい）
#   ./scripts/check-appstore-app.sh <Nanopic.app> --distribution   # ＋配布用の署名（App ID・チーム ID・プロファイル）
#
# build-appstore.sh が作った直後のアプリにかけ、package-appstore.sh ができた .pkg から取り出したアプリにもう一度かける
# （署名や .pkg 化で中身が変わっていないこと、提出するものそのものが検査を通ることを確かめる）。
set -euo pipefail
APP="${1:?使い方: check-appstore-app.sh <Nanopic.app> [--signed|--distribution]}"
MODE="${2:-}"
TEAM_ID="${TEAM_ID:-5WLLZHK49R}"
BUNDLE_ID=com.hashrock.nanopic
SRC_ENT="$(cd "$(dirname "$0")" && pwd)/appstore.entitlements"

BIN="$APP/Contents/MacOS/Nanopic"
RES="$APP/Contents/Resources"
PLIST="$APP/Contents/Info.plist"
fail() { echo "NG: $*" >&2; exit 1; }
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }
[ -x "$BIN" ] || fail "$BIN がありません"

# --- エージェント連携（MCP）が入っていないこと ---
# MCP はコンパイルの段階で外す（Package.swift の NANOPIC_APPSTORE）。実行時に隠しているのではないことを、
# バイナリに MCP の文字列・シンボルが残っていないことで確かめる。memcpy は "mcp" を含むので除く
LEFT=$( { strings -a "$BIN"; nm "$BIN" 2>/dev/null; } | grep -iE 'mcp|NanopicAgent|AgentTool' | grep -v memcpy || true)
if [ -n "$LEFT" ]; then
    echo "App Store 用のバイナリにエージェント連携（MCP）が残っています:" >&2
    echo "$LEFT" | head -20 >&2
    exit 1
fi
# 待ち受け（NWListener）も入っていないこと
if nm "$BIN" 2>/dev/null | grep -q 'NWListener'; then fail "バイナリに NWListener（待ち受け）が残っています"; fi
if otool -L "$BIN" | grep -q 'Network.framework'; then fail "バイナリが Network.framework をリンクしています"; fi
# 訳の表にも入っていないこと（エージェント連携の画面の訳は Agent の表に分けてあり、App Store 用には入れない）
if [ -e "$RES/en.lproj/Agent.strings" ] || [ -e "$RES/ja.lproj/Agent.strings" ]; then
    fail "エージェント連携の訳（Agent.strings）が入っています"
fi
LEFT=$(for f in "$RES"/*.lproj/*; do plutil -convert xml1 -o - "$f" 2>/dev/null || cat "$f"; done | grep -iE 'mcp|エージェント|agent' || true)
if [ -n "$LEFT" ]; then
    echo "App Store 用の訳の表にエージェント連携（MCP）の文言が残っています:" >&2
    echo "$LEFT" | head -20 >&2
    exit 1
fi
echo "OK: MCP の文字列・シンボル、待ち受けは入っていません（${BIN}、訳の表）"

# --- App Store に出すのに要るもの ---
plutil -lint "$PLIST" >/dev/null || fail "Info.plist が壊れています"
[ "$(pb CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "CFBundleIdentifier が $BUNDLE_ID ではありません"
[ -n "$(pb LSApplicationCategoryType)" ] || fail "LSApplicationCategoryType がありません"
[ "$(pb ITSAppUsesNonExemptEncryption)" = "false" ] || fail "ITSAppUsesNonExemptEncryption が false ではありません"
[ -n "$(pb CFBundleShortVersionString)" ] && [ -n "$(pb CFBundleVersion)" ] || fail "版がありません"
[ -n "$(pb LSMinimumSystemVersion)" ] || fail "LSMinimumSystemVersion がありません"
# Xcode で作ったアプリに入る項目（どの Xcode・SDK で作ったか。build-appstore.sh が足す）
for KEY in BuildMachineOSBuild DTCompiler DTPlatformName DTPlatformVersion DTPlatformBuild DTSDKName DTSDKBuild DTXcode DTXcodeBuild; do
    [ -n "$(pb $KEY)" ] || fail "Info.plist に $KEY がありません"
done
plutil -lint "$RES/PrivacyInfo.xcprivacy" >/dev/null || fail "PrivacyInfo.xcprivacy がありません"
# 表示言語: 日本語・英語（App Store の「言語」に出る）。Info.plist の申告と、Resources の .lproj の両方
[ "$(pb CFBundleDevelopmentRegion)" = "ja" ] || fail "CFBundleDevelopmentRegion が ja ではありません"
[ "$(pb CFBundleLocalizations:0) $(pb CFBundleLocalizations:1)" = "ja en" ] || fail "CFBundleLocalizations が ja・en ではありません"
for TABLE in Localizable Names; do
    plutil -lint "$RES/en.lproj/$TABLE.strings" >/dev/null || fail "en.lproj/$TABLE.strings がありません"
    [ -f "$RES/ja.lproj/$TABLE.strings" ] || fail "ja.lproj/$TABLE.strings がありません"
done
# アイコンは icns に 512pt の @2x（1024px）まで入っていること
ICONTMP=$(mktemp -d)
iconutil -c iconset "$RES/AppIcon.icns" -o "$ICONTMP/AppIcon.iconset" || fail "AppIcon.icns を読めません"
[ -f "$ICONTMP/AppIcon.iconset/icon_512x512@2x.png" ] && [ -f "$ICONTMP/AppIcon.iconset/icon_512x512.png" ] || fail "AppIcon.icns に 512pt（@1x・@2x）がありません"
rm -rf "$ICONTMP"
ARCHS=$(lipo -archs "$BIN")
case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) ;; *) fail "ユニバーサルではありません（${ARCHS}）" ;; esac
# entitlement のもと: Sandbox あり、通信なし、余計な例外なし
plutil -lint "$SRC_ENT" >/dev/null || fail "entitlements が壊れています"
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$SRC_ENT")" = "true" ] || fail "app-sandbox がありません"
if grep -qE 'com\.apple\.security\.(network|temporary-exception|cs\.)' "$SRC_ENT"; then fail "entitlements に通信か例外が入っています"; fi
echo "OK: Info.plist・PrivacyInfo・アイコン・表示言語（ja・en）・entitlements（$(pb CFBundleShortVersionString) / $(pb CFBundleVersion)、${ARCHS}）"

[ -n "$MODE" ] || exit 0

# --- 署名に入った entitlement ---
SIGNED=$(mktemp -t nanopic-signed).plist
codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$SIGNED" || fail "署名の entitlement を読めません"
ent() { /usr/libexec/PlistBuddy -c "Print :$1" "$SIGNED" 2>/dev/null; }
# キーの一覧（1 行に 1 つ）
keys() { plutil -convert xml1 -o - "$1" | sed -n 's/^[[:space:]]*<key>\(.*\)<\/key>.*/\1/p' | sort; }
[ "$(ent com.apple.security.app-sandbox)" = "true" ] || fail "署名に app-sandbox がありません"
if keys "$SIGNED" | grep -qE 'com\.apple\.security\.(network|temporary-exception|cs\.)'; then fail "署名に通信か例外の entitlement が入っています"; fi

case "$MODE" in
--signed)
    echo "OK: 署名に app-sandbox があり、通信の entitlement はありません"
    ;;
--distribution)
    codesign --verify --deep --strict "$APP" || fail "署名が壊れています"
    [ "$(ent com.apple.application-identifier)" = "$TEAM_ID.$BUNDLE_ID" ] || fail "署名の application-identifier が $TEAM_ID.$BUNDLE_ID ではありません"
    [ "$(ent com.apple.developer.team-identifier)" = "$TEAM_ID" ] || fail "署名の team-identifier が $TEAM_ID ではありません"
    # もとの entitlement + App ID + チーム ID のほかに、何も足されていないこと（get-task-allow など）
    WANT=$( { keys "$SRC_ENT"; echo com.apple.application-identifier; echo com.apple.developer.team-identifier; } | sort)
    [ "$(keys "$SIGNED")" = "$WANT" ] || fail "署名の entitlement が想定と違います: $(keys "$SIGNED" | tr '\n' ' ')"
    AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    case "$AUTHORITY" in
    "Apple Distribution: "*|"3rd Party Mac Developer Application: "*) ;;
    *) fail "配布用の証明書で署名されていません（${AUTHORITY:-署名なし}）" ;;
    esac
    # プロファイル: 入っていて、App ID が合っていること
    PROFILE_PLIST=$(mktemp -t nanopic-profile).plist
    security cms -D -i "$APP/Contents/embedded.provisionprofile" > "$PROFILE_PLIST" 2>/dev/null || fail "embedded.provisionprofile がありません"
    PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST")
    [ "$PROFILE_APP_ID" = "$TEAM_ID.$BUNDLE_ID" ] || fail "プロファイルの App ID が違います: ${PROFILE_APP_ID}"
    echo "OK: 配布用の署名（${AUTHORITY}）、プロファイル「$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST")」、entitlement は Sandbox + App ID + チーム ID だけ"
    rm -f "$PROFILE_PLIST"
    ;;
*) fail "知らないオプション: $MODE" ;;
esac
rm -f "$SIGNED"
