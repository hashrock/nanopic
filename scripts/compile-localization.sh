#!/bin/bash
# 訳のカタログ（Resources/*.xcstrings）を .lproj にして、アプリ（.app）の Resources に入れる
#
#   ./scripts/compile-localization.sh <.app の Resources> <表の名前>...
#   ./scripts/compile-localization.sh build/Nanopic.app/Contents/Resources Localizable Names Agent
#
# SwiftPM（swift build）は .xcstrings をコンパイルしないので、Xcode の xcstringstool で自分で変換する。
# できるのは en.lproj/<表>.strings（複数形のあるものは .stringsdict も）。元の言語（日本語）はキーがそのまま文言なので、
# ja.lproj には空の表を置く（フォルダーがあることで、アプリが日本語に対応していると分かる）。
# iPad 版は Xcode が同じカタログをビルドのときに変換する（iPad/project.yml）。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"
shift
mkdir -p "$OUT/ja.lproj" "$OUT/en.lproj"
for TABLE in "$@"; do
    xcrun xcstringstool compile "Resources/$TABLE.xcstrings" --output-directory "$OUT"
    [ -f "$OUT/en.lproj/$TABLE.strings" ] || { echo "NG: en.lproj/$TABLE.strings ができませんでした" >&2; exit 1; }
    if [ ! -f "$OUT/ja.lproj/$TABLE.strings" ]; then
        printf '/* 元の言語（日本語）。キーがそのまま文言になる */\n' > "$OUT/ja.lproj/$TABLE.strings"
    fi
done
