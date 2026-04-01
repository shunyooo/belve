# dock-code

1つのウィンドウで複数の開発環境（SSH / DevContainer）を管理・即座に切り替えできるデスクトップアプリ。VS Code フォーク。

```
┌─────────────────────────────────────────────────────────────┐
│ [P1] [P2] [P3] │  Terminal  │  VS Code Editor              │
│                 │            │                              │
│  ProjectBar     │  Pane      │  ActivityBar + Sidebar +     │
│  (プロジェクト   │  Container │  Editor + Panel              │
│   切り替え)      │            │                              │
│                 │────────────│                              │
│                 │  Terminal  │                              │
└─────────────────────────────────────────────────────────────┘
```

## 特徴

- **マルチプロジェクト** — 1ウィンドウ内で複数プロジェクトを独立管理。各プロジェクトが独自の Extension Host・リモート接続を持つ
- **SSH リモート開発** — VSDA 不要の自前 SSH resolver。プロジェクト内で SSH 先のファイル編集・ターミナル実行
- **DevContainer** — SSH 先で `devcontainer up` → コンテナ内で開発。SSH ↔ DevContainer のシームレスな切り替え
- **PaneContainer** — ProjectBar の右に自由分割できるターミナル/ペイン領域
- **VS Code 互換** — マーケットプレイス拡張、テーマ、キーバインドがそのまま使える

## アーキテクチャ

```
Single BrowserWindow
├── Project 1 (main webContents) ── Extension Host 1 ── SSH/DevContainer A
├── Project 2 (WebContentsView)  ── Extension Host 2 ── SSH/DevContainer B
├── Project 3 (WebContentsView)  ── Extension Host 3 ── SSH/DevContainer C
└── プロジェクト切り替え: view.setVisible(true/false) + webContents.focus()
```

各プロジェクトは Electron の `WebContentsView` で独立した renderer プロセスとして動作。プロジェクト間の切り替えはビューの表示/非表示で瞬時に行われる。

## 開発

```bash
# 依存インストール
npm ci

# 型チェック
npm run compile-check-ts-native

# トランスパイル
NODE_OPTIONS="--experimental-strip-types" node build/next/index.ts transpile

# 起動
./scripts/code.sh

# REH サーバービルド（GitHub Actions で自動実行）
NODE_OPTIONS="--experimental-strip-types" node --max-old-space-size=8192 \
  ./node_modules/gulp/bin/gulp.js vscode-reh-linux-x64
```

## ライセンス

[MIT](LICENSE.txt)

VS Code のフォークです。元のリポジトリ: [microsoft/vscode](https://github.com/microsoft/vscode)
