#!/bin/bash
# App Store 用のビルドを作る: エージェント連携（MCP）を外した build/appstore/Nanopic.app
#
#   ./scripts/build-appstore.sh
#   SANDBOX=1 ./scripts/build-appstore.sh   # App Sandbox を付けて ad-hoc 署名する（手元で Sandbox の中の動作を確かめる用）
#
# 配布用の署名と .pkg 化は scripts/package-appstore.sh（このスクリプトを呼んでから署名する）
#
# できたアプリは scripts/check-appstore-app.sh で検査する: MCP の文字列・シンボルが残っていないこと
# （MCP はコンパイルの段階で外す。Package.swift の NANOPIC_APPSTORE）、App Store に出すのに要る
# Info.plist の項目・プライバシーマニフェスト・アイコン・表示言語・entitlement。
# ここでは配布用の署名・App Store Connect への送信はしない（Apple とは通信しない）。
set -euo pipefail
cd "$(dirname "$0")/.."

NANOPIC_APPSTORE=1 ./scripts/build-app.sh
APP=build/appstore/Nanopic.app
PLIST="$APP/Contents/Info.plist"

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

if [ "${SANDBOX:-}" = "1" ]; then
    codesign --force --sign - --entitlements scripts/appstore.entitlements "$APP"
    ./scripts/check-appstore-app.sh "$APP" --signed
    echo "App Sandbox を付けて ad-hoc 署名しました（配布用の署名ではありません）"
else
    ./scripts/check-appstore-app.sh "$APP"
fi
