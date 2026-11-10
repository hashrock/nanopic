#!/bin/bash
# Mac App Store に出す .pkg を作る: build/appstore/Nanopic.app を配布用に署名し、dist/appstore/Nanopic-<版>.pkg に固める
#
#   PROFILE=~/Downloads/Nanopic_Mac_App_Store.provisionprofile ./scripts/package-appstore.sh
#   ./scripts/package-appstore.sh --dry-run   # 証明書なしで流れだけ確かめる（ad-hoc 署名、署名なしの .pkg。提出はできない）
#
# 要るもの（Apple Developer で作ってキーチェーンに入れておく。作り方は README の「Mac App Store」）:
#   - 証明書 "Apple Distribution: ..."（アプリの署名。古い名前は "3rd Party Mac Developer Application: ..."）
#   - 証明書 "3rd Party Mac Developer Installer: ..."（.pkg の署名。新しい名前は "Mac Installer Distribution"）
#   - Mac App Store 用のプロビジョニングプロファイル（App ID com.hashrock.nanopic）→ PROFILE で渡す
# 名前が違うときは APP_IDENTITY / PKG_IDENTITY で渡す。
#
# このスクリプトは Apple と通信しない（タイムスタンプも付けない。App Store 用の署名には要らない）。
# できた .pkg のアップロード（Transporter か xcrun altool）はここではしない。
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-5WLLZHK49R}"
BUNDLE_ID=com.hashrock.nanopic
APP=build/appstore/Nanopic.app
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

find_identity() { security find-identity -v | sed -n "s/.*\"\\($1[^\"]*\\)\".*/\\1/p" | head -1; }
if [ "$DRY_RUN" = 0 ]; then
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
        echo "用意のしかたは README の「Mac App Store」。流れだけ確かめるなら --dry-run" >&2
        exit 1
    fi
fi

./scripts/build-appstore.sh

# 配布用の entitlement: Sandbox のもの + どのアプリ・どのチームか（プロファイルと合っていること）
ENT=$(mktemp -t nanopic-entitlements).plist
cp scripts/appstore.entitlements "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
                        -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENT"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist/appstore

if [ "$DRY_RUN" = 1 ]; then
    codesign --force --sign - --entitlements "$ENT" "$APP"
    PKG="dist/appstore/Nanopic-$VERSION-unsigned.pkg"
    rm -f "$PKG"
    productbuild --component "$APP" /Applications "$PKG"
else
    # プロファイルの App ID とチームが合っているか（合っていないと、アップロードしてから弾かれる）
    PROFILE_PLIST=$(mktemp -t nanopic-profile).plist
    security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
    PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST")
    if [ "$PROFILE_APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]; then
        echo "プロファイルの App ID が違います: ${PROFILE_APP_ID}（要るのは $TEAM_ID.$BUNDLE_ID）" >&2
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
    pkgutil --check-signature "$PKG" | head -5
fi

# 署名に入った entitlement を確かめる
SIGNED=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
echo "$SIGNED" | grep -q 'com.apple.security.app-sandbox' || { echo "NG: 署名に app-sandbox がありません" >&2; exit 1; }
if echo "$SIGNED" | grep -q 'com.apple.security.network'; then echo "NG: 署名に network.* が入っています" >&2; exit 1; fi
pkgutil --payload-files "$PKG" | grep -q 'Nanopic.app/Contents/MacOS/Nanopic' || { echo "NG: .pkg にアプリが入っていません" >&2; exit 1; }

echo "Built $PKG ($(du -h "$PKG" | cut -f1))"
if [ "$DRY_RUN" = 1 ]; then
    echo "（--dry-run: ad-hoc 署名・署名なしの .pkg。App Store には出せません）"
else
    echo "アップロードは Transporter.app にドラッグするか:"
    echo "  xcrun altool --upload-package $PKG --type macos --apple-id <App の Apple ID（数字）> --bundle-id $BUNDLE_ID \\\\"
    echo "      --bundle-version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist") --bundle-short-version-string $VERSION -u <Apple ID> -p @keychain:<項目名>"
fi
