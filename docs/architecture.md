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

### Phase 2: コマンドパレット + プロジェクト管理

**ゴール**: プロジェクトの追加/削除、コマンドパレットで操作

1. コマンドパレット UI（Cmd+Shift+P でオーバーレイ表示）
2. プロジェクト追加/削除（名前入力 → ローカルシェルで起動）
3. プロジェクト永続化（JSON ファイル）
4. **検証**: Cmd+Shift+P → 「New Project」→ 名前入力 → サイドバーに追加

### Phase 3: SSH 接続

**ゴール**: コマンドパレットから SSH 接続

1. `~/.ssh/config` 読み取り → ホスト一覧取得
2. コマンドパレット → 「SSH Connect」→ ホスト選択 → PTYService で ssh 起動
3. プロジェクトの接続状態を更新
4. **検証**: コマンドパレット → SSH Connect → ホスト選択 → リモートシェル操作

### Phase 4: コードエディタ

**ゴール**: リモートファイルを開いて編集・保存

1. `WebEditor/` で CodeMirror 6 をバンドル（esbuild → `editor-bundle.js`）
2. `CodeEditorView.swift` — WKWebView + `WKScriptMessageHandler` で双方向通信
3. Swift ↔ CodeMirror プロトコル: `openFile(content, language)`, `onContentChanged(content)`
4. ファイルツリー表示（`ssh` + `ls` or `find` で取得）
5. ファイル保存（`ssh` 経由で書き込み）
6. **検証**: ファイルツリーからファイル選択 → 編集 → 保存 → 再度開いて反映確認

### Phase 5: Markdown WYSIWYG

**ゴール**: `.md` ファイルを WYSIWYG で編集

1. `WebMarkdown/` で Milkdown Crepe をバンドル
2. `MarkdownEditorView.swift` — CodeEditorView と同じ通信パターン
3. `.md` ファイルは自動的に Markdown エディタで開く
4. **検証**: `.md` ファイル開く → WYSIWYG 編集 → 保存

### Phase 6: DevContainer

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

### サイドバーレイアウト（cmux 参考）

```
┌──────────────┐
│ [+] [🔔]  [◀]│  ← 上部: 追加 / 通知 / トグル
├──────────────┤
│ ● Project 1  │  ← プロジェクト一覧（スクロール）
│ ● Project 2  │    将来: git ブランチ / 通知テキスト
│ ○ Project 3  │
│              │
└──────────────┘
```

- **上部**: 「+」プロジェクト追加 / 「🔔」通知パネル / 「◀」サイドバートグル
- **中央**: プロジェクト一覧。将来的に各項目にメタデータ（git ブランチ、通知）を追加
- ショートカット: Cmd+1/2/3 でプロジェクト切り替え

### プロジェクトモデル

**プロジェクト = 空の箱**。作成時は名前だけ。接続先はコマンドパレットから後で設定。

```
Project {
    id: UUID
    name: String
    connectionType: .local | .ssh(host) | .devContainer(host, containerPath)
    remotePath: String?     // リモートのワークスペースパス
}
```

**ライフサイクル:**
1. 「+ New Project」→ 名前入力 → ローカルシェルで起動
2. コマンドパレット（Cmd+Shift+P）→「SSH Connect」→ `~/.ssh/config` のホスト一覧から選択
3. コマンドパレット → 「Open in DevContainer」→ devcontainer.json のあるパスを指定
4. プロジェクトの接続状態はサイドバーのドットで表示（緑=接続中、青=ローカル）

**初期画面（プロジェクトゼロの時）:**
```
┌──────────────────────────────┐
│                              │
│     Welcome to Belve         │
│                              │
│  [📁 Open Local Folder]     │
│  [🔗 Connect via SSH]       │
│  [📦 Open DevContainer]     │
│                              │
└──────────────────────────────┘
```

### コマンドパレット（Cmd+Shift+P）

VS Code の Cmd+Shift+P に相当。プロジェクト内の全操作のエントリポイント。

**コマンド一覧:**
- `SSH Connect` — `~/.ssh/config` のホスト一覧 → 選択 → SSH 接続
- `Open DevContainer` — リモートパス指定 → `devcontainer up` → コンテナ接続
- `Open File` — ファイルツリーからファイルを開く（Preview エリア）
- `Split Terminal` — ターミナルペインを分割
- `Switch Project` — Cmd+1/2/3 でも可

**UI:** ウィンドウ中央にオーバーレイ表示。テキスト入力 + フィルタリングされたコマンドリスト。

### UX 原則

- **キーボードファースト**: Cmd+Shift+P でコマンドパレット、Cmd+P でファイル検索
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

## UI 自動テスト（osascript + screencapture）

Claude Code から直接 UI の確認・操作ができる。Computer Use が使えない環境でも macOS 標準ツールで代替可能。

### スクショ確認

```bash
# ビルド → 起動 → 前面化 → スクショ
swift build && open .build/arm64-apple-macosx/debug/Belve
sleep 2
osascript -e 'tell app "System Events" to tell process "Belve" to set frontmost to true'
sleep 1
screencapture -x /tmp/belve-ui.png
# Read ツールで /tmp/belve-ui.png を読めば画像として確認できる
```

### UI 要素の列挙

```bash
osascript -e 'tell app "System Events" to tell process "Belve" to get entire contents of window 1'
```

### UI 操作

```bash
# テキスト要素をクリック
osascript -e 'tell app "System Events" to tell process "Belve" to click static text "clay-api-flamel" of group 1 of window 1'

# キーボードショートカット
osascript -e 'tell app "System Events" to tell process "Belve" to keystroke "k" using command down'

# 座標クリック
osascript -e 'tell app "System Events" to click at {400, 300}'

# ウィンドウリサイズ
osascript -e 'tell app "System Events" to tell process "Belve" to set size of window 1 to {1200, 800}'
```

### 注意点

- SPM バイナリは `application "Belve"` では認識されない → `System Events` の `process "Belve"` 経由で操作
- Accessibility 権限がターミナルに必要（System Settings > Privacy & Security > Accessibility）
- `screencapture -x` はシャッター音なし

## 完了した作業

- ✅ アプリシェル（SwiftUI + ダークテーマ + タイトルバー非表示）
- ✅ サイドバー（プロジェクト一覧 + トグル）
- ✅ ローカルターミナル（SwiftTerm + PTYService + .app バンドル）
- ✅ Command / Preview 分割レイアウト（カスタムドラッグ分割）
- ✅ コマンドパレット（Cmd+Shift+P）
- ✅ プロジェクト管理（追加/削除 + JSON 永続化）
- ✅ SSH 接続（~/.ssh/config 読み取り + コマンドパレットから選択）
- ✅ コードエディタ（CodeMirror 6、15言語対応）
- ✅ ファイルツリー（ローカル + SSH リモート対応）
- ✅ Markdown WYSIWYG（Milkdown Crepe）
- ✅ 画像プレビュー（NSImage）
- ✅ ターミナルペイン分割（縦分割）
- ✅ UI 自動テスト基盤（osascript + screencapture）

## TODO / ロードマップ

### 高優先度

#### ターミナルペイン縦横分割
- 現状は縦分割のみ。縦横自由なグリッド分割に対応する
- cmux のような柔軟なペイン管理を目指す
- ペインごとに独立した PTY セッション

#### 通知システム（cmux 参考）
- AI エージェント（Claude Code 等）の実行状態を通知
- ペインに通知リング（視覚的インジケーター）
- サイドバーに git ブランチ、PR 情報、最新通知を表示
- Cmd+Shift+U で未読通知にジャンプ
- 参考: https://github.com/manaflow-ai/cmux

**技術実装メモ:**
- 検知方法1: ターミナル出力の OSC エスケープシーケンス（OSC 9 / 99 / 777）を監視。SwiftTerm の TerminalViewDelegate にハンドラーあり
- 検知方法2: CLI コマンド（`belve notify "message"`）をエージェントが明示的に呼ぶ
- Claude Code 連携: `hooks.Notification` で `belve notify` を実行するよう設定
- 表示: PTY 出力 → SwiftTerm が OSC パース → delegate コールバック → サイドバー/ペイン UI 更新

#### ファイルツリーのキーボード操作
- 矢印キー上下でフォーカス移動
- 右矢印でフォルダ展開、左矢印で折りたたみ
- Enter でファイルを開く
- フォーカス中のアイテムをハイライト表示

#### DevContainer 対応
- コマンドパレットから「Open in DevContainer」
- `devcontainer` CLI 連携（`devcontainer up` / `exec`）
- SSH ホスト上のコンテナに接続

#### ファイル保存
- エディタでの変更をローカル/SSH 先に書き戻す
- Cmd+S ショートカット
- 未保存状態のインジケーター（ドット付きタブ）

### 中優先度

#### ターミナルエンジン差し替え検討
- 現在: SwiftTerm（Pure Swift、組み込みやすい）
- 候補: libghostty（GPU 120fps、Ghostty config 互換）
- Protocol で抽象化済みなので差し替え可能
- libghostty は Zig ビルドが必要、導入コスト高
- パフォーマンス問題が出てから検討で OK

#### Web プレビュー
- Preview エリアでの Web ページ表示
- ポートフォワード先のローカルサーバー確認用
- cmux の agent-browser のような scriptable API も検討

#### プロジェクト名編集
- サイドバーでダブルクリック or コマンドパレットで名前変更

### 低優先度

#### hiddenTitleBar の復活
- 現在は `unifiedCompact` + `.hiddenTitleBar` 使用中
- SwiftTerm の AutoLayout クラッシュは解決済み
- よりクリーンなウィンドウクロムを目指す

#### tmux 連携
- SSH 先の tmux セッションにアタッチ
- ペイン状態の保持・復元

## 競合・参考プロダクト

| プロダクト | 特徴 | Belve との差分 |
|---|---|---|
| [cmux](https://github.com/manaflow-ai/cmux) | AI エージェント管理特化、libghostty、通知システム | Belve はエディタ + ファイルツリー + マルチプロジェクト。cmux は DevContainer 非対応 |
| VS Code | フル IDE、拡張機能エコシステム | Belve は軽量ネイティブ、余計な機能なし |
| Cursor | AI エディタ | Belve はターミナル中心、マルチプロジェクト |
| Zed | ネイティブ高速エディタ | Belve は SSH/DevContainer + ターミナルが主軸 |
| Warp | モダンターミナル | Belve はエディタ + ファイルツリー + プロジェクト管理 |
