# Belve TODO

## 直近の優先タスク

### ターミナル (GhosttyKit)
- [ ] クリップボード対応（コピー & ペースト）— `read_clipboard_cb` / `write_clipboard_cb` で NSPasteboard 連携
- [ ] テキスト選択（マウスドラッグ、ダブルクリック単語選択、トリプルクリック行選択）
- [ ] URL リンク検出 & Cmd+クリックでブラウザオープン
- [ ] IME 入力の位置制御（日本語入力のカーソル位置）— `ghostty_surface_ime_point`
- [ ] スクロールバー表示（フェード付き）
- [ ] Ghostty config のユーザーカスタマイズ対応（フォント、テーマ等）
- [ ] SSH / DevContainer 接続時のターミナル（現在 SwiftTerm ベースの `TerminalPaneView` が残ってる）
- [ ] GhosttyKit.xcframework のダウンロードスクリプト（`scripts/setup.sh`）

### エージェント連携
- [ ] SSH/DevContainer でのエージェントイベントリレー（`ssh tail -f` 方式の Swift 実装）
- [ ] デスクトップ通知（`UserNotifications` framework）— completed, error, waiting 遷移時
- [ ] 通知クリック → プロジェクト切替 + ペインフォーカス
- [ ] セッションラベル自動生成（Claude Code の初回プロンプトから要約）
- [ ] ゾンビセッション自動クリーンアップ（タイムアウトベース）

### レイアウト & UI
- [ ] ペイン分割の操作 UI（コンテキストメニュー or ショートカット）
- [ ] ペインサイズのドラッグリサイズ
- [ ] ペイン状態の永続化（分割構成を再起動後も保持）
- [ ] サイドバーの折りたたみ / 展開
- [ ] プロジェクト追加 UI の改善（SSH ホスト選択、DevContainer 選択）
- [ ] `Cmd+'` でアプリ表示/非表示トグル（グローバルホットキー）

### キーボードショートカット
- [ ] tmux 互換 prefix (Ctrl+A) — ペイン移動/分割/閉じる/ズーム
- [ ] プロジェクト切替 (Cmd+1-9)
- [ ] エリア循環移動 (Option+;/')
- [ ] コマンドパレット (Cmd+Shift+P)

## 中期タスク

### SSH / DevContainer
- [ ] SSH 自動再接続（切断時のリトライ）
- [ ] DevContainer ワークスペースフォルダ自動オープン
- [ ] Belve CLI (`belve` + `claude` wrapper) のリモート自動デプロイ
- [ ] リモートの hooks 自動設定

### エディタ / プレビュー
- [ ] コードエディタ（CodeMirror 6 + WKWebView）
- [ ] Markdown WYSIWYG エディタ（Milkdown + WKWebView）
- [ ] ファイルツリーのリモートファイル対応
- [ ] メディアプレビュー

### セッション永続化
- [ ] tmux 統合（リモート側セッション永続化）
- [ ] プロジェクト構成の永続化（接続先、ペインレイアウト、開いているファイル）
- [ ] アプリ再起動時の自動復元

## 長期タスク

### マルチデバイス同期
- [ ] アカウントベースの状態保存
- [ ] デバイス間でプロジェクト一覧と接続先の同期
- [ ] 同一セッションへの同時接続のコンフリクト回避

### GhosttyKit 高度な機能
- [ ] 画像プロトコル（ターミナル内画像表示）
- [ ] ウィンドウ背景透過 / ガラスエフェクト
- [ ] 検索（Find）機能
- [ ] リガチャフォント対応

## 実装済み

### ターミナル
- [x] GhosttyKit ベースのターミナル描画（Metal GPU レンダリング）
- [x] キーボード入力、マウス、スクロール
- [x] リサイズ + rewrap
- [x] シェル汎用 PATH 注入（ZDOTDIR for zsh, --rcfile for bash, --init-command for fish）
- [x] ANSI カラーパレット（One Dark 風）

### エージェント連携
- [x] ファイルベースのエージェントイベント監視（`/tmp/belve-agent-events`）
- [x] Claude Code hooks 自動注入（`claude` wrapper + `belve claude-hook`）
- [x] ProjectListView のステータスドット表示（running=青, waiting=黄, completed=緑）
- [x] paneId → projectId マッピング

### アプリ基盤
- [x] macOS ネイティブ SwiftUI アプリ
- [x] マルチプロジェクト管理（サイドバー）
- [x] ペイン分割（縦横グリッド）
- [x] コマンドパレット
- [x] フォルダブラウザ (Cmd+O)
- [x] SSH / DevContainer 接続
