# nanopic website

ビルド不要の静的サイト。`index.html` をブラウザで開いて確認できます。

- `index.html`: ページ本文
- `style.css`: レスポンシブスタイル
- `assets/`: ロゴ（`Resources/AppIcon.svg` の写し）とスクリーンショット

## GitHub Pages

リポジトリの Settings → Pages → Build and deployment → Source で **GitHub Actions** を選択してください。
`main` に push すると `.github/workflows/pages.yml` が `website/` を公開します。Actions から手動実行も可能です。

ダウンロードボタンは最新の GitHub Release にリンクしています。
