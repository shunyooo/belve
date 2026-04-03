# Belve — ネイティブ macOS マルチプロジェクト開発環境

## Context

dock-code（VS Code フォーク）は WebContentsView の ServiceWorker 問題、CSP 制約、upstream との乖離など、VS Code のフレームワーク全体を背負うコストが高い。macOS ネイティブ（Swift/SwiftUI）でゼロから作り直し、必要な機能だけをクリーンに実装する。

## 技術スタック

| レイヤー | 技術 |
|---|---|
| App Shell / UI | SwiftUI (macOS 14+) |
| ターミナル | SwiftTerm (NSViewRepresentable) |
| コードエディタ | WKWebView + CodeMirror 6 |
| Markdown WYSIWYG | WKWebView + Milkdown (Crepe) |
| SSH | system `ssh` コマンド（Process + PTY） |
| DevContainer | `devcontainer` CLI |
| ビルド | Swift Package Manager |

## プロジェクト構造

```
dock/                              # リポジトリルート
├── CLAUDE.md                      # AI コンテキスト（< 300行）
├── archived/                      # 旧 dock-code ソース
├── Package.swift
├── Sources/
│   └── Belve/
│       ├── BelveApp.swift          # @main エントリポイント
│       ├── Models/
│       │   ├── Project.swift      # プロジェクト定義
│       │   └── FileItem.swift     # ファイルツリー
│       ├── Views/
│       │   ├── MainWindow.swift          # NavigationSplitView ルート
│       │   ├── Sidebar/
│       │   │   └── ProjectListView.swift
│       │   ├── Command/                  # 左ペイン: 指示するエリア
│       │   │   ├── CommandArea.swift     # ターミナルペインコンテナ
│       │   │   └── TerminalPaneView.swift # NSViewRepresentable + SwiftTerm
│       │   └── Preview/                  # 右ペイン: 確認するエリア
│       │       ├── PreviewArea.swift     # タブ切り替えコンテナ
│       │       ├── FileTreeView.swift    # ファイルツリー（サイドバー or タブ）
│       │       ├── CodeEditorView.swift  # WKWebView + CodeMirror
│       │       ├── MarkdownEditorView.swift # WKWebView + Milkdown
│       │       └── WebPreviewView.swift  # WKWebView (汎用プレビュー)
│       ├── Services/
│       │   ├── ProjectManager.swift      # プロジェクト永続化・切り替え
│       │   ├── SSHService.swift          # SSH 接続管理
│       │   ├── DevContainerService.swift # devcontainer CLI ラッパー
│       │   └── PTYService.swift          # PTY 生成・管理
│       └── Resources/
│           ├── editor.html        # CodeMirror バンドル済み HTML
│           ├── editor-bundle.js   # CodeMirror 6 (rollup/esbuild バンドル)
│           ├── markdown.html      # Milkdown バンドル済み HTML
│           └── markdown-bundle.js # Milkdown Crepe バンドル
├── Tests/
│   └── BelveTests/
├── WebEditor/                     # CodeMirror ビルド用 npm プロジェクト
│   ├── package.json
│   ├── src/editor.ts
│   └── rollup.config.js
└── WebMarkdown/                   # Milkdown ビルド用 npm プロジェクト
    ├── package.json
    ├── src/index.ts
    └── rollup.config.js
```

## AI エージェントフレンドリーな設計原則

- **1ファイル1責務**: 各 Swift ファイルは 1 つの型/プロトコルのみ定義
- **Protocol 駆動**: Service 層はすべて Protocol で定義 → 実装を差し替え可能
- **明示的な依存**: DI はイニシャライザ注入。グローバル状態を避ける
- **小さいファイル**: 200行以下を目安。AI が全体を読んで変更しやすい
- **CLAUDE.md**: ルートに全体構造、各ディレクトリに個別コンテキスト
- **命名規則**: View は `*View`、Service は `*Service`、Model はそのまま

## 実装フェーズ（全機能を薄く）

### Phase 1: アプリシェル + ローカルターミナル

**ゴール**: 起動してローカルシェルが使える

1. SPM プロジェクト作成（`Package.swift`, `BelveApp.swift`）
2. `MainWindow.swift` — `NavigationSplitView` でサイドバー + メインエリア
3. `ProjectListView.swift` — プロジェクト一覧（ハードコードでOK）
4. `TerminalView.swift` — SwiftTerm を NSViewRepresentable でラップ、ローカルシェル起動
5. **検証**: `swift build && swift run` でアプリ起動、ターミナルで `ls` 等が動く

### Phase 2: SSH 接続

**ゴール**: SSH 先のリモートシェルが使える

1. `SSHService.swift` — `Process` で `ssh` コマンドを PTY 経由で起動
2. `PTYService.swift` — `forkpty` / `openpty` ラッパー
3. `TerminalView` に SSH セッション接続機能を追加
4. プロジェクトモデルに SSH ホスト情報を追加
5. **検証**: サイドバーからプロジェクト選択 → SSH 接続 → リモートシェル操作

### Phase 3: コードエディタ

**ゴール**: リモートファイルを開いて編集・保存

1. `WebEditor/` で CodeMirror 6 をバンドル（esbuild → `editor-bundle.js`）
2. `CodeEditorView.swift` — WKWebView + `WKScriptMessageHandler` で双方向通信
3. Swift ↔ CodeMirror プロトコル: `openFile(content, language)`, `onContentChanged(content)`
4. ファイルツリー表示（`ssh` + `ls` or `find` で取得）
5. ファイル保存（`ssh` 経由で書き込み）
6. **検証**: ファイルツリーからファイル選択 → 編集 → 保存 → 再度開いて反映確認

### Phase 4: Markdown WYSIWYG

**ゴール**: `.md` ファイルを WYSIWYG で編集

1. `WebMarkdown/` で Milkdown Crepe をバンドル
2. `MarkdownEditorView.swift` — CodeEditorView と同じ通信パターン
3. `.md` ファイルは自動的に Markdown エディタで開く
4. **検証**: `.md` ファイル開く → WYSIWYG 編集 → 保存

### Phase 5: DevContainer + プロジェクト永続化

**ゴール**: devcontainer.json があるプロジェクトでコンテナ内開発

1. `DevContainerService.swift` — `devcontainer up` / `exec` CLI ラッパー
2. `ProjectManager.swift` — JSON でプロジェクト一覧を永続化
3. プロジェクト追加/削除 UI
4. **検証**: プロジェクト追加 → SSH → devcontainer up → コンテナ内ターミナル

## UI/UX 設計

### レイアウト — Command / Preview 2ペイン

左右分割。左は「指示するエリア（Command）」、右は「確認するエリア（Preview）」。

```
┌─────────────────────────────────────────────────────┐
│ ┌────┐ ┌──────────────────┬────────────────────┐    │
│ │    │ │  Command          │  Preview            │    │
│ │ P  │ │                  │ ┌──┐               │    │
│ │ r  │ │ ┌──────┬───────┐ │ │📁│ file-tree     │    │
│ │ o  │ │ │Term 1│Term 2 │ │ ├──┘               │    │
│ │ j  │ │ │      │       │ │ │ [main.swift]      │    │
│ │ e  │ │ │      │       │ │ │ ┌──────────────┐ │    │
│ │ c  │ │ ├──────┴───────┤ │ │ │ Code Editor  │ │    │
│ │ t  │ │ │ Terminal 3    │ │ │ │ / Markdown   │ │    │
│ │ s  │ │ │              │ │ │ │ / Web View   │ │    │
│ │    │ │ │              │ │ │ └──────────────┘ │    │
│ └────┘ │ └──────────────┘ │ └──────────────────┘    │
│        └──────────────────┴────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

**Command エリア（左）**: ターミナルペイン。縦横自由にグリッド分割可能。tmux 連携で SSH 先のシェルを操作
**Preview エリア（右）**: ファイルツリー + コードエディタ / Markdown WYSIWYG / Web プレビューをタブ切り替え。ファイルの中身を確認・編集する場所

### UX 原則

- **キーボードファースト**: Cmd+K でコマンドパレット、Cmd+P でファイル検索
- **高速切り替え**: Cmd+1/2/3 でプロジェクト切り替え
- **ネイティブ感**: macOS 標準のショートカット遵守、spring アニメーション
- **ミニマル**: 不要な UI 要素は出さない。Typora / Linear のような体験

## 検証方法

```bash
# ビルド & 実行
swift build && swift run Belve

# テスト
swift test

# WebEditor ビルド（CodeMirror バンドル）
cd WebEditor && npm install && npm run build

# WebMarkdown ビルド（Milkdown バンドル）
cd WebMarkdown && npm install && npm run build
```

## 初手の作業

1. 現在の dock-code ソースを `archived/` に移動
2. `Package.swift` + `BelveApp.swift` + `MainWindow.swift` を作成
3. SwiftTerm を SPM 依存に追加
4. TerminalView でローカルシェルが動くところまで
