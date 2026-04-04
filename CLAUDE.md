# CLAUDE.md

## Belve とは

macOS ネイティブ（Swift/SwiftUI）のマルチプロジェクト開発環境。SSH/DevContainer リモート接続、ターミナル、コードエディタ、Markdown WYSIWYG を統合。

## ビルドと開発

```bash
# ビルド & 実行（直接実行。`open` は Terminal.app が起動するので使わない）
swift build && .build/arm64-apple-macosx/debug/Belve &

# テスト
swift test
```

## アーキテクチャ

詳細は `docs/architecture.md` を参照。

### レイアウト

- **Sidebar**: プロジェクト一覧
- **Command エリア（左）**: ターミナルペイン（縦横グリッド分割可能）
- **Preview エリア（右）**: ファイルツリー + エディタ / Markdown / Web プレビュー

### 技術スタック

- SwiftUI (macOS 14+) — アプリシェル
- SwiftTerm — ターミナルエミュレーション（NSViewRepresentable）
- WKWebView + CodeMirror 6 — コードエディタ
- WKWebView + Milkdown — Markdown WYSIWYG
- system `ssh` + PTY — SSH 接続
- `devcontainer` CLI — DevContainer

### プロジェクト構造

```
Sources/Belve/
├── BelveApp.swift          # @main
├── Models/                # データモデル
├── Views/
│   ├── MainWindow.swift   # NavigationSplitView ルート
│   ├── Sidebar/           # プロジェクト一覧
│   ├── Command/           # ターミナルペイン（左）
│   └── Preview/           # エディタ・プレビュー（右）
├── Services/              # ビジネスロジック
└── Resources/             # WebView 用 HTML/JS バンドル
```

## 設計原則

- 1ファイル1責務、200行以下目安
- Protocol 駆動（Service 層は Protocol で定義）
- DI はイニシャライザ注入
- View は `*View`、Service は `*Service`

## コーディング規約

- インデントはタブ
- Swift naming conventions（PascalCase: 型、camelCase: 変数/関数）

## UI 自動テスト

osascript + screencapture でビルド→起動→スクショ確認→操作テストが可能。詳細は `docs/architecture.md` の「UI 自動テスト」セクション参照。

```bash
# 基本フロー
swift build && open .build/arm64-apple-macosx/debug/Belve
sleep 2
osascript -e 'tell app "System Events" to tell process "Belve" to set frontmost to true'
screencapture -x /tmp/belve-ui.png
# Read ツールで画像確認
```
