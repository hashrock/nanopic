#!/bin/bash
# 配布用のビルドを作る: Developer ID で署名し、公証して dist/Nanopic-<版>.zip に固める
#
#   ./scripts/release.sh            # 公証まで（キーチェーンのプロファイル nanovid を使う）
#   NOTARY_PROFILE= ./scripts/release.sh   # 署名だけ（公証しない）
#
# 公証の資格情報は初回だけ保存しておく:
#   xcrun notarytool store-credentials nanovid --apple-id <Apple ID> --team-id 5WLLZHK49R --password <App 用パスワード>
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: YU IWAI (5WLLZHK49R)"
NOTARY_PROFILE="${NOTARY_PROFILE-nanovid}"
APP=build/Nanopic.app

./scripts/build-app.sh
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="dist/Nanopic-$VERSION.zip"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
fi

echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
