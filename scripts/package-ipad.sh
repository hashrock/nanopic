#!/bin/bash
# iPad 版を App Store Connect に出す .ipa を作る: Archive → クラウド署名で書き出し → 検査（→ --upload なら上げる）
#
#   ./scripts/package-ipad.sh            # dist/appstore/ipad/Nanopic-<版>-<ビルド番号>.ipa を作って検査する
#   ./scripts/package-ipad.sh --upload   # ＋検査が通ったら App Store Connect に上げる（TestFlight に出る）
#
# 署名は Mac 版（package-appstore.sh）と同じく Xcode に任せる（自動署名・クラウド署名）。
# 要るもの: Xcode の Settings > Accounts にチームの Apple ID でサインインしていること、xcodegen（iPad/project.yml から作り直す）。
# 版とビルド番号は iPad/project.yml の MARKETING_VERSION・CURRENT_PROJECT_VERSION。同じ版・ビルド番号はもう上げられない。
set -euo pipefail
cd "$(dirname "$0")/.."
# 一時ファイルはこのフォルダーに置き、終わったら（途中で失敗しても）フォルダーごと消す
WORKTMP=$(mktemp -d -t nanopic)
trap 'rm -rf "$WORKTMP"' EXIT

TEAM_ID="${TEAM_ID:-5WLLZHK49R}"
BUNDLE_ID=com.hashrock.nanopic
UPLOAD=0
for ARG in "$@"; do
    case "$ARG" in
    --upload) UPLOAD=1 ;;
    *) echo "使い方: $0 [--upload]" >&2; exit 1 ;;
    esac
done

WORK=build/ipad
ARCHIVE=$WORK/NanopicPad.xcarchive
EXPORT=$WORK/export
OUT=dist/appstore/ipad
mkdir -p "$WORK" "$OUT"
rm -rf "$ARCHIVE" "$EXPORT"
fail() { echo "NG: $*" >&2; exit 1; }

# project.yml とプロジェクトを合わせる（版を変えて xcodegen を忘れても、古い版で出さない）
command -v xcodegen >/dev/null || fail "xcodegen がありません（brew install xcodegen）"
(cd iPad && xcodegen -q)

# --- Archive（Release。署名は自動） ---
LOG=$WORK/archive.log
echo "Archive します（ログは ${LOG}）"
xcodebuild -project iPad/NanopicPad.xcodeproj -scheme NanopicPad -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates archive > "$LOG" 2>&1 \
    || { grep -E 'error:' "$LOG" | tail -20 >&2; fail "Archive に失敗しました（${LOG}）"; }
APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/Nanopic.app"
apb() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_IN_ARCHIVE/Info.plist"; }
VERSION=$(apb CFBundleShortVersionString)
BUILD_NUMBER=$(apb CFBundleVersion)
[ "$(apb CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "CFBundleIdentifier が $BUNDLE_ID ではありません"
IPA="$OUT/Nanopic-$VERSION-$BUILD_NUMBER.ipa"
# 同じ版・ビルド番号はもう上げられないので、あるならたいてい上げたもの。上書きしない（作り直すならビルド番号を上げるか、消してから）
[ ! -e "$IPA" ] || fail "$IPA はもうあります。上げたものを残すため上書きしません（iPad/project.yml の CURRENT_PROJECT_VERSION を上げるか、消してから）"

# destination: export は書き出すだけ、upload は App Store Connect に上げる
OPTIONS="$WORKTMP/export-options.plist"
write_options() {
    cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$1</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <!-- 版とビルド番号は project.yml のまま（Xcode に書き換えさせない） -->
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
}
export_archive() { # $1: destination, $2: 書き出し先, $3: ログ
    write_options "$1"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
        -exportPath "$2" -allowProvisioningUpdates > "$3" 2>&1 \
        || { grep -E 'error|Error' "$3" | tail -20 >&2; return 1; }
}

# --- クラウド署名で書き出す ---
echo "クラウド署名で書き出します（$VERSION / ${BUILD_NUMBER}。ログは $WORK/export.log）"
export_archive export "$EXPORT" "$WORK/export.log" || fail "書き出しに失敗しました（$WORK/export.log）"
[ -f "$EXPORT/Nanopic.ipa" ] || fail "$EXPORT/Nanopic.ipa ができていません"
cp "$EXPORT/Nanopic.ipa" "$IPA"

# --- 検査: .ipa の中のアプリ（署名、entitlement、版、プライバシーマニフェスト） ---
EXPANDED="$WORKTMP/expanded"
unzip -q "$IPA" -d "$EXPANDED"
INNER="$EXPANDED/Payload/Nanopic.app"
[ -d "$INNER" ] || fail ".ipa にアプリが入っていません"
ipb() { /usr/libexec/PlistBuddy -c "Print :$1" "$INNER/Info.plist" 2>/dev/null; }
[ "$(ipb CFBundleShortVersionString) $(ipb CFBundleVersion)" = "$VERSION $BUILD_NUMBER" ] || fail ".ipa の中のアプリの版が変わっています"
codesign --verify --deep --strict "$INNER" || fail "署名が壊れています"
AUTHORITY=$(codesign -dvv "$INNER" 2>&1 | sed -n 's/^Authority=//p' | head -1)
case "$AUTHORITY" in "Apple Distribution: "*|"iPhone Distribution: "*) ;; *) fail "配布用の証明書で署名されていません（${AUTHORITY:-署名なし}）" ;; esac
SIGNED="$WORKTMP/signed.plist"
codesign -d --entitlements - --xml "$INNER" 2>/dev/null > "$SIGNED" || fail "署名の entitlement を読めません"
ent() { /usr/libexec/PlistBuddy -c "Print :$1" "$SIGNED" 2>/dev/null; }
[ "$(ent get-task-allow)" != "true" ] || fail "get-task-allow が入っています（開発用の署名）"
[ "$(ent com.apple.developer.ubiquity-kvstore-identifier)" = "$TEAM_ID.$BUNDLE_ID" ] || fail "ubiquity-kvstore-identifier（iCloud 同期）が $TEAM_ID.$BUNDLE_ID ではありません"
ent com.apple.developer.icloud-container-identifiers | grep -q 'iCloud.com.hashrock.nanopic' || fail "iCloud container（iCloud.com.hashrock.nanopic）がありません"
[ -f "$INNER/embedded.mobileprovision" ] || fail "embedded.mobileprovision がありません"
plutil -lint "$INNER/PrivacyInfo.xcprivacy" >/dev/null || fail "PrivacyInfo.xcprivacy がありません"
for L in ja en; do [ -d "$INNER/$L.lproj" ] || fail "$L.lproj がありません"; done
echo "OK: 配布用の署名（${AUTHORITY%%:*}）、iCloud（書類・同期）、版 $VERSION / ${BUILD_NUMBER}、プライバシーマニフェスト、表示言語"
echo "Built $IPA ($(du -h "$IPA" | cut -f1))"

if [ "$UPLOAD" = 1 ]; then
    # --- 検査を通ったので、同じアーカイブを App Store Connect に上げる（Apple と通信する） ---
    echo "App Store Connect に上げます（$VERSION / ${BUILD_NUMBER}。ログは $WORK/upload.log）"
    export_archive upload "$WORK/upload" "$WORK/upload.log" \
        || fail "アップロードに失敗しました（$WORK/upload.log）。同じビルド番号をもう上げていないか確かめてください"
    echo "OK: 上げました。App Store Connect の処理が終わると TestFlight に出ます"
else
    echo "上げるときは --upload を付けて作り直してください"
fi
