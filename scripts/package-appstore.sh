#!/bin/bash
# Mac App Store に出す .pkg を作る: build/appstore/Nanopic.app を配布用に署名し、dist/appstore/Nanopic-<版>.pkg に固める
#
#   ./scripts/package-appstore.sh             # クラウド署名（既定）。手元に配布用の証明書は要らない
#   PROFILE=~/Downloads/Nanopic_Mac_App_Store.provisionprofile ./scripts/package-appstore.sh --local
#                                             # 手元のキーチェーンの証明書で署名する
#   ./scripts/package-appstore.sh --dry-run   # 署名なしで流れだけ確かめる（ad-hoc 署名、署名なしの .pkg。提出はできない）
#   ./scripts/package-appstore.sh --upload    # クラウド署名で作って検査し、通ったら App Store Connect に上げる（TestFlight に出る）
#
# クラウド署名（既定）:
#   アプリを .xcarchive の形に包み、xcodebuild -exportArchive -allowProvisioningUpdates に渡す。
#   Xcode が Apple のサーバーにある証明書（Cloud Managed Apple Distribution）でアプリを署名し、
#   プロファイル（Mac Team Store Provisioning Profile: com.hashrock.nanopic）を作って埋め込み、.pkg にして署名する。
#   要るもの: Xcode の Settings > Accounts にチーム（TEAM_ID）の Apple ID でサインインしていること
#   （クラウド署名を使えるのは Account Holder / Admin か、「Access to Cloud Managed Distribution Certificate」を持つ人）。
#   Apple と通信するのは、この署名とプロファイルの作成だけ。
#
# 手元の証明書で署名する（--local）:
#   Apple Developer で作ってキーチェーンに入れておく（作り方は README の「手元の証明書で署名するとき」）:
#   - 証明書 "Apple Distribution: ..."（アプリの署名。古い名前は "3rd Party Mac Developer Application: ..."）
#   - 証明書 "3rd Party Mac Developer Installer: ..."（.pkg の署名。新しい名前は "Mac Installer Distribution"）
#   - Mac App Store 用のプロビジョニングプロファイル（App ID com.hashrock.nanopic）→ PROFILE で渡す
#   名前が違うときは APP_IDENTITY / PKG_IDENTITY で渡す。Apple とは通信しない（タイムスタンプも付けない）。
#
# どの道でも、できた .pkg からアプリを取り出して scripts/check-appstore-app.sh でもう一度検査する。
#
# アップロード（--upload）:
#   検査が全部通ったら、同じ .xcarchive を destination: upload でもう一度 xcodebuild -exportArchive に渡す。
#   認証はクラウド署名と同じ Xcode のアカウント（鍵やパスワードは要らない）。上げたビルドは App Store Connect の
#   処理が終わると TestFlight に出る。同じ版・ビルド番号はもう上げられないので、上げ直すときはビルド番号を上げる。
set -euo pipefail
cd "$(dirname "$0")/.."
# 一時ファイルはこのフォルダーに置き、終わったら（途中で失敗しても）フォルダーごと消す
WORKTMP=$(mktemp -d -t nanopic)
trap 'rm -rf "$WORKTMP"' EXIT

TEAM_ID="${TEAM_ID:-5WLLZHK49R}"
BUNDLE_ID=com.hashrock.nanopic
APP=build/appstore/Nanopic.app
MODE=cloud
UPLOAD=0
for ARG in "$@"; do
    case "$ARG" in
    --cloud) MODE=cloud ;;
    --local) MODE=local ;;
    --dry-run) MODE=dry-run ;;
    --upload) UPLOAD=1 ;;
    *) echo "使い方: $0 [--cloud（既定）| --local | --dry-run] [--upload]" >&2; exit 1 ;;
    esac
done
if [ "$UPLOAD" = 1 ] && [ "$MODE" != cloud ]; then
    echo "--upload はクラウド署名（既定）とだけ使えます" >&2
    exit 1
fi

find_identity() { security find-identity -v | sed -n "s/.*\"\\($1[^\"]*\\)\".*/\\1/p" | head -1; }
if [ "$MODE" = local ]; then
    APP_IDENTITY="${APP_IDENTITY:-$(find_identity 'Apple Distribution: ')}"
    [ -n "$APP_IDENTITY" ] || APP_IDENTITY=$(find_identity '3rd Party Mac Developer Application: ')
    PKG_IDENTITY="${PKG_IDENTITY:-$(find_identity '3rd Party Mac Developer Installer: ')}"
    MISSING=()
    [ -n "$APP_IDENTITY" ] || MISSING+=("証明書 Apple Distribution（アプリの署名）")
    [ -n "$PKG_IDENTITY" ] || MISSING+=("証明書 3rd Party Mac Developer Installer / Mac Installer Distribution（.pkg の署名）")
    [ -n "${PROFILE:-}" ] && [ -f "${PROFILE:-}" ] || MISSING+=("プロビジョニングプロファイル（PROFILE=<.provisionprofile のパス>）")
    if [ ${#MISSING[@]} -gt 0 ]; then
        echo "足りないもの:" >&2
        printf '  - %s\n' "${MISSING[@]}" >&2
        echo "用意のしかたは README の「手元の証明書で署名するとき」。証明書なしで作るならオプションなし（クラウド署名）、流れだけ確かめるなら --dry-run" >&2
        exit 1
    fi
fi

# クラウド署名に渡すアプリは、Sandbox の entitlement を付けて ad-hoc 署名しておく（Xcode がそれを引き継いで署名し直す）
if [ "$MODE" = cloud ]; then SANDBOX=1 ./scripts/build-appstore.sh; else ./scripts/build-appstore.sh; fi

pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION=$(pb CFBundleShortVersionString)
BUILD_NUMBER=$(pb CFBundleVersion)
mkdir -p dist/appstore

# 配布用の entitlement: Sandbox のもの + どのアプリ・どのチームか（プロファイルと合っていること）
# + ブラシ・パレットの iCloud 同期（キー値ストア。iPad 版と同じ識別子）。
# iCloud の entitlement はプロファイルなしでは起動できなくなるので、手元で試す ad-hoc 署名（build-appstore.sh）には入れず、ここでだけ足す
ENT="$WORKTMP/entitlements.plist"
cp scripts/appstore.entitlements "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
                        -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
                        -c "Add :com.apple.developer.ubiquity-kvstore-identifier string $TEAM_ID.$BUNDLE_ID" "$ENT"

case "$MODE" in
cloud)
    # --- .xcarchive の形に包む（Xcode の Archive と同じ並び） ---
    ARCHIVE=build/appstore/Nanopic.xcarchive
    EXPORT=build/appstore/export
    rm -rf "$ARCHIVE" "$EXPORT"
    # 配布用の entitlement（iCloud 同期を含む）で ad-hoc 署名し直す。Xcode はこれを引き継いで署名し直す
    codesign --force --sign - --entitlements "$ENT" "$APP"
    mkdir -p "$ARCHIVE/Products/Applications"
    ditto "$APP" "$ARCHIVE/Products/Applications/Nanopic.app"
    # dSYM があれば入れる（Organizer でクラッシュの場所を読むのに使う。なくても書き出せる）
    DSYM=.build-appstore/apple/Products/Release/Nanopic.dSYM
    if [ -d "$DSYM" ]; then
        mkdir -p "$ARCHIVE/dSYMs"
        ditto "$DSYM" "$ARCHIVE/dSYMs/Nanopic.app.dSYM"
    fi
    ARCHS=$(lipo -archs "$APP/Contents/MacOS/Nanopic")
    cat > "$ARCHIVE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ApplicationProperties</key>
    <dict>
        <key>ApplicationPath</key><string>Applications/Nanopic.app</string>
        <key>Architectures</key><array>$(for A in $ARCHS; do printf '<string>%s</string>' "$A"; done)</array>
        <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
        <key>CFBundleShortVersionString</key><string>$VERSION</string>
        <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
        <key>SigningIdentity</key><string>-</string>
        <key>Team</key><string>$TEAM_ID</string>
    </dict>
    <key>ArchiveVersion</key><integer>2</integer>
    <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
    <key>Name</key><string>Nanopic</string>
    <key>SchemeName</key><string>Nanopic</string>
</dict>
</plist>
PLIST
    plutil -lint "$ARCHIVE/Info.plist" >/dev/null
    OPTIONS="$WORKTMP/export-options.plist"
    # destination: export は書き出すだけ、upload は App Store Connect に上げる（--upload で、検査のあとに使う）
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
    <!-- 版とビルド番号はアプリの Info.plist のまま（Xcode に書き換えさせない） -->
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><false/>
</dict>
</plist>
PLIST
    }
    write_options export
    # --- クラウド署名（ここだけ Apple と通信する: 署名とプロファイルの作成） ---
    LOG=build/appstore/export.log
    echo "クラウド署名で書き出します（xcodebuild -exportArchive。ログは ${LOG}）"
    if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
            -exportPath "$EXPORT" -allowProvisioningUpdates > "$LOG" 2>&1; then
        grep -E 'error|Error' "$LOG" | tail -20 >&2 || tail -20 "$LOG" >&2
        echo "NG: 書き出しに失敗しました（${LOG}）。Xcode の Settings > Accounts にチーム $TEAM_ID でサインインしているか確かめてください" >&2
        exit 1
    fi
    [ -f "$EXPORT/Nanopic.pkg" ] || { echo "NG: $EXPORT/Nanopic.pkg ができていません（${LOG}）" >&2; exit 1; }
    PKG="dist/appstore/Nanopic-$VERSION.pkg"
    rm -f "$PKG"
    cp "$EXPORT/Nanopic.pkg" "$PKG"
    # どの証明書・プロファイルで署名されたか
    SUMMARY="$EXPORT/DistributionSummary.plist"
    sp() { /usr/libexec/PlistBuddy -c "Print :Nanopic.pkg:0:$1" "$SUMMARY" 2>/dev/null || true; }
    echo "署名: $(sp certificate:type)（$(sp certificate:dateExpires) まで） / プロファイル: $(sp profile:name)（$(sp profile:dateExpires) まで）"
    ;;
local)
    # プロファイルの App ID とチームが合っているか（合っていないと、アップロードしてから弾かれる）
    PROFILE_PLIST="$WORKTMP/profile.plist"
    security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
    PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST")
    if [ "$PROFILE_APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]; then
        echo "プロファイルの App ID が違います: ${PROFILE_APP_ID}（要るのは $TEAM_ID.${BUNDLE_ID}）" >&2
        exit 1
    fi
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    # 拡張属性（ダウンロードの印など）が残っていると弾かれる
    xattr -cr "$APP"
    codesign --force --timestamp=none --sign "$APP_IDENTITY" --entitlements "$ENT" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    PKG="dist/appstore/Nanopic-$VERSION.pkg"
    rm -f "$PKG"
    productbuild --component "$APP" /Applications --sign "$PKG_IDENTITY" "$PKG"
    ;;
dry-run)
    codesign --force --sign - --entitlements "$ENT" "$APP"
    PKG="dist/appstore/Nanopic-$VERSION-unsigned.pkg"
    rm -f "$PKG"
    productbuild --component "$APP" /Applications "$PKG"
    ;;
esac

# --- できた .pkg を検査する: 署名、中のアプリ（取り出して、作った直後と同じ検査をもう一度） ---
if [ "$MODE" != dry-run ]; then
    PKG_SIGNER=$(pkgutil --check-signature "$PKG" | sed -n 's/^ *1\. //p' | head -1)
    case "$PKG_SIGNER" in
    "3rd Party Mac Developer Installer: "*|"Mac Installer Distribution: "*) echo "OK: .pkg の署名（${PKG_SIGNER}）" ;;
    *) pkgutil --check-signature "$PKG" | head -8 >&2; echo "NG: .pkg が Installer の証明書で署名されていません" >&2; exit 1 ;;
    esac
fi
EXPANDED="$WORKTMP/expanded"
mkdir -p "$EXPANDED"
pkgutil --expand-full "$PKG" "$EXPANDED/pkg"
INNER=$(find "$EXPANDED/pkg" -maxdepth 3 -name Nanopic.app -type d | head -1)
[ -n "$INNER" ] || { echo "NG: .pkg にアプリが入っていません" >&2; exit 1; }
echo "--- .pkg の中のアプリを検査 ---"
if [ "$MODE" = dry-run ]; then
    ./scripts/check-appstore-app.sh "$INNER" --signed
else
    TEAM_ID="$TEAM_ID" ./scripts/check-appstore-app.sh "$INNER" --distribution
fi
ipb() { /usr/libexec/PlistBuddy -c "Print :$1" "$INNER/Contents/Info.plist"; }
[ "$(ipb CFBundleShortVersionString) $(ipb CFBundleVersion)" = "$VERSION $BUILD_NUMBER" ] \
    || { echo "NG: .pkg の中のアプリの版が変わっています（$(ipb CFBundleShortVersionString) / $(ipb CFBundleVersion)）" >&2; exit 1; }

echo "Built $PKG ($(du -h "$PKG" | cut -f1)、$VERSION / $BUILD_NUMBER)"
if [ "$UPLOAD" = 1 ]; then
    # --- 検査を通ったので、同じアーカイブを App Store Connect に上げる（Apple と通信する） ---
    write_options upload
    LOG=build/appstore/upload.log
    echo "App Store Connect に上げます（$VERSION / ${BUILD_NUMBER}。ログは ${LOG}）"
    if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
            -exportPath build/appstore/upload -allowProvisioningUpdates > "$LOG" 2>&1; then
        grep -E 'error|Error' "$LOG" | tail -20 >&2 || tail -20 "$LOG" >&2
        echo "NG: アップロードに失敗しました（${LOG}）。同じビルド番号をもう上げていないか確かめてください" >&2
        exit 1
    fi
    echo "OK: 上げました。App Store Connect の処理が終わると TestFlight に出ます"
elif [ "$MODE" = dry-run ]; then
    echo "（--dry-run: ad-hoc 署名・署名なしの .pkg。App Store には出せません）"
else
    echo "アップロードは --upload を付けて作り直すか、Transporter.app にドラッグするか:"
    echo "  xcrun altool --upload-package $PKG --type macos --apple-id <App の Apple ID（数字）> --bundle-id $BUNDLE_ID \\\\"
    echo "      --bundle-version $BUILD_NUMBER --bundle-short-version-string $VERSION -u <Apple ID> -p @keychain:<項目名>"
fi
