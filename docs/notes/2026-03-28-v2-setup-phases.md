# v2 (Swift 書き直し) の立ち上げフェーズ記録

**更新**: 2026-03-28 (計画時)
**ステータス**: 全フェーズ完了 (歴史アーカイブ)

2026-03-28 頃に v1 (VS Code fork) から Swift/SwiftUI ネイティブへ書き直す際の実装フェーズ計画。すべて完了済み。

## Phase 1: アプリシェル + ローカルターミナル

**ゴール**: 起動してローカルシェルが使える

1. SPM プロジェクト作成（`Package.swift`, `BelveApp.swift`）
2. `MainWindow.swift` — `NavigationSplitView` でサイドバー + メインエリア
3. `ProjectListView.swift` — プロジェクト一覧（ハードコードでOK）
4. `TerminalView.swift` — SwiftTerm を NSViewRepresentable でラップ、ローカルシェル起動
5. **検証**: `swift build && swift run` でアプリ起動、ターミナルで `ls` 等が動く

## Phase 2: コマンドパレット + プロジェクト管理

**ゴール**: プロジェクトの追加/削除、コマンドパレットで操作

1. コマンドパレット UI（Cmd+Shift+P でオーバーレイ表示）
2. プロジェクト追加/削除（名前入力 → ローカルシェルで起動）
3. プロジェクト永続化（JSON ファイル）

## Phase 3: SSH 接続

**ゴール**: コマンドパレットから SSH 接続

1. `~/.ssh/config` 読み取り → ホスト一覧取得
2. コマンドパレット → 「SSH Connect」→ ホスト選択 → PTYService で ssh 起動
3. プロジェクトの接続状態を更新

## Phase 4: コードエディタ

**ゴール**: リモートファイルを開いて編集・保存

1. `WebEditor/` で CodeMirror 6 をバンドル（esbuild → `editor-bundle.js`）
2. `CodeEditorView.swift` — WKWebView + `WKScriptMessageHandler` で双方向通信
3. ファイルツリー表示、保存

## Phase 5: Markdown WYSIWYG

**ゴール**: `.md` ファイルを WYSIWYG で編集

1. `WebMarkdown/` で Milkdown Crepe をバンドル
2. `MarkdownEditorView.swift` — CodeEditorView と同じ通信パターン

## Phase 6: DevContainer

**ゴール**: devcontainer.json があるプロジェクトでコンテナ内開発

1. `DevContainerService.swift` — `devcontainer up` / `exec` CLI ラッパー (後にロジックは `ProjectStore` に吸収)
2. プロジェクト追加/削除 UI
3. **検証**: プロジェクト追加 → SSH → devcontainer up → コンテナ内ターミナル

## 完了した作業 (2026-04 時点)

- ✅ アプリシェル（SwiftUI + ダークテーマ + タイトルバー非表示）
- ✅ サイドバー（プロジェクト一覧 + トグル）
- ✅ ローカルターミナル（初期は SwiftTerm、後に xterm.js + belve-persist へ移行）
- ✅ Command / Preview 分割レイアウト（カスタムドラッグ分割）
- ✅ コマンドパレット（Cmd+Shift+P）
- ✅ プロジェクト管理（追加/削除 + JSON 永続化）
- ✅ SSH 接続（~/.ssh/config 読み取り + コマンドパレットから選択）
- ✅ コードエディタ（CodeMirror 6、15言語対応）
- ✅ ファイルツリー（ローカル + SSH リモート対応 + VS Code 風 sort + icon）
- ✅ Markdown WYSIWYG（Milkdown Crepe）
- ✅ 画像プレビュー（NSImage）
- ✅ ターミナルペイン分割（縦横自由なグリッド）
- ✅ UI 自動テスト基盤（osascript + screencapture）
- ✅ DevContainer 連携
- ✅ Claude Code / Codex hooks 連携によるエージェントセッション監視
- ✅ SSH ControlMaster + port forward 多重化 (MaxSessions 問題解消)
- ✅ belve-persist TCP 化でセッション永続化

## その後の主要マイルストーン

- **v2.0.0 (2026-04-18)**: 新リポジトリ `shunyooo/belve` への移行、VS Code fork 解消
- **v2.0.2 (2026-04-18)**: 初の DMG release、`@xterm/addon-webgl` 追加
