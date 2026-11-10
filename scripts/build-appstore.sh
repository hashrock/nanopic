#!/bin/bash
# App Store 用のビルドを作る: エージェント連携（MCP）を外した build/appstore/Nanopic.app
#
#   ./scripts/build-appstore.sh
#   SANDBOX=1 ./scripts/build-appstore.sh   # App Sandbox を付けて ad-hoc 署名する（手元で Sandbox の中の動作を確かめる用）
#
# MCP はコンパイルの段階で外す（Package.swift の NANOPIC_APPSTORE）。実行時に隠しているのではないことを、
# できたバイナリに MCP の文字列・シンボルが残っていないことで確かめる。
# ここでは署名（配布用）・Sandbox・App Store Connect への送信はしない。
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
echo "OK: MCP の文字列・シンボル、待ち受けは入っていません（${BIN}）"

if [ "${SANDBOX:-}" = "1" ]; then
    codesign --force --sign - --entitlements scripts/appstore.entitlements build/appstore/Nanopic.app
    echo "App Sandbox を付けて ad-hoc 署名しました（配布用の署名ではありません）"
fi
