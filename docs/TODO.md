# Belve TODO

## 既知のバグ

### エディタ表示時にサイドバーとターミナル間に空白エリアが出る
エディタ（Cmd+E）を表示すると、サイドバーとターミナル（CommandArea）の間に意図しない暗い空白エリアが表示される。`commandAreaFraction` やスプリット計算の問題の可能性。

## 直近の優先タスク

### ターミナル (xterm.js + WKWebView)
- [x] クリップボード対応（コピー & ペースト）
- [x] テキスト選択 — xterm.js ネイティブ（ローカル）/ OSC 52 経由（SSH/DevContainer）
- [x] スクロール — Swift NSEvent monitor → SGR マウスシーケンス → PTY
- [x] ペイン split 時のクラッシュ修正 — フラットレイアウト方式
- [x] スクロールが正しいペインにのみ反映 — hitTest でホバーペイン判定
- [ ] URL リンク検出 & Cmd+クリックでブラウザオープン
- [ ] スクロールバー表示（フェード付き）

### セッション永続化 (belve-persist)
- [x] tmux 依存を排除、Go 製 belve-persist で置き換え
- [x] ローカル + SSH + DevContainer 全対応
- [x] PTY パススルー（マウス/OSC/エスケープシーケンス干渉なし）
- [x] クロスコンパイル（linux/amd64, linux/arm64, darwin/arm64）
- [x] SCP でリモートデプロイ（base64 では大きすぎるため）
- [x] SIGHUP 無視で SSH 切断後も生存
- [x] 256KB リプレイバッファ（再接続時に画面内容を復元）
- [x] PTYService を raw mode に設定（PTY 2段重ねの CR/LF 問題を解消）
- [ ] セッション再接続の安定化（daemon+client 分離は未完、auto-attach 方式で動作中）

### エージェント連携
- [x] OSC エスケープシーケンスでエージェントステータスを転送
- [x] デスクトップ通知（`UserNotifications` framework）— waiting 遷移時にバナー+サウンド
- [x] 通知クリック → プロジェクト切替 + ペインフォーカス
- [x] セッションラベル自動生成（Claude Code の初回プロンプトから TopBar に表示）
- [ ] ゾンビセッション自動クリーンアップ（タイムアウトベース）

### レイアウト & UI
- [x] ペイン分割 (Cmd+D / Cmd+Shift+D)
- [x] ペインサイズのドラッグリサイズ（比率ベース、PaneDivider コンポーネント）
- [x] ペイン閉じる (Cmd+W)
- [x] ペイン状態の永続化（分割構成を再起動後も保持）
- [x] サイドバーの折りたたみ / 展開（アニメーション付き）
- [x] TopBar に接続状態バッジ（SSH/DevContainer/Local）
- [x] DevContainer 検出バナー（右下）
- [x] プロジェクト右クリックコンテキストメニュー（Rename/Delete）

### キーボードショートカット
- [x] プロジェクト切替 (Cmd+1-9)
- [x] プロジェクト前後移動 (Cmd+[ / Cmd+])
- [x] ペインフォーカス移動 (Cmd+; / Cmd+')
- [x] エディタフォーカス (Cmd+L)
- [x] エディタトグル (Cmd+E)
- [x] サイドバートグル (Cmd+\)
- [x] ファイルツリートグル (Cmd+Shift+E)
- [x] ペイン分割 (Cmd+D / Cmd+Shift+D)
- [x] ペイン閉じる (Cmd+W)
- [x] コマンドパレット (Cmd+Shift+P)
- [x] ファイル検索 (Cmd+P)
- [x] フォルダブラウザ (Cmd+O)

## 中期タスク

### SSH / DevContainer
- [x] SSH ControlMaster で接続多重化（2本目以降は瞬時接続）
- [x] belve-persist でセッション永続化（tmux 不要）
- [x] DevContainer バナー自動検出
- [x] Belve CLI (`belve` + `claude` wrapper) のリモート自動デプロイ
- [ ] SSH 自動再接続（切断時のリトライ）

### 実行基盤
- [x] `ExecutionContext` — 統一的なコマンド実行レイヤー（local/ssh/devContainer）
- [x] `ProjectStore` — プロジェクト状態の一元管理（CRUD, 永続化, 選択, 状態リセット）
- [x] `Project.executionContext` — プロジェクトから実行コンテキストを自動決定
- [x] `Project.effectivePath` — コンテキストに応じたパス解決

### エディタ / プレビュー
- [x] コードエディタ（CodeMirror 6 + WKWebView）
- [x] Markdown WYSIWYG エディタ
- [x] ファイルツリー（ローカル + SSH + DevContainer 対応）
- [x] ファイル検索 (Cmd+P)
- [ ] メディアプレビュー改善

## 実装済み

### ターミナル
- [x] xterm.js (WKWebView) ベースのターミナル描画
- [x] キーボード入力、マウス、スクロール
- [x] リサイズ + rewrap
- [x] シェル汎用 PATH 注入（ZDOTDIR for zsh, --rcfile for bash, --init-command for fish）
- [x] ANSI カラーパレット（Catppuccin Mocha）
- [x] OSC 52 クリップボード連携（tmux/SSH 越しのコピー）
- [x] ペイン分割時の NSView キャッシュ（元ペインの再初期化回避）

### セッション永続化 (belve-persist)
- [x] Go 製の dtach ライクなプロセス永続化ツール
- [x] Unix ソケットベースのクライアント接続
- [x] PTY 完全パススルー（マウス/OSC 干渉なし）
- [x] 静的バイナリ（CGO_ENABLED=0）で任意の Linux ディストリに対応
- [x] DevContainer: ホスト側で belve-persist が docker exec を管理

### エージェント連携
- [x] OSC ベースのエージェントイベント監視
- [x] Claude Code hooks 自動注入（`claude` wrapper + `belve claude-hook`）
- [x] ProjectListView のステータスドット表示（running=青, waiting=黄, completed=緑）
- [x] paneId → projectId マッピング
- [x] デスクトップ通知（UserNotifications framework）
- [x] 通知クリック → プロジェクト切替

### アプリ基盤
- [x] macOS ネイティブ SwiftUI アプリ
- [x] マルチプロジェクト管理（サイドバー）
- [x] プロジェクト切替で接続維持（opacity ベース表示切替）
- [x] ペイン分割（縦横グリッド、ドラッグリサイズ）
- [x] コマンドパレット
- [x] フォルダブラウザ (Cmd+O、Tab でフォルダ移動、Enter で確定)
- [x] SSH / DevContainer 接続
- [x] SSH ControlMaster 多重化
- [x] TopBar 接続状態バッジ
- [x] クラッシュシグナルハンドラ
- [x] バイナリ日時ログ（ビルドキャッシュ検証用）

### 設計上の注意
- **ペイン分割はフラットレイアウト方式** — 再帰 PaneTreeView だと SwiftUI がビューを破棄/再作成してクラッシュ。ZStack + ForEach でフラットに描画。
- **SwiftUI CommandGroup + @Published = クラッシュ** — performKeyEquivalent のコールスタック内で @Published 変更すると EXC_BAD_ACCESS。`.onKeyPress` を使う。
- **SPM ビルドキャッシュ** — インクリメンタルビルドが変更を反映しないことがある。`swift package clean` でフルリビルド。
- **PTYService は raw mode** — belve-persist との PTY 2段重ねで CR/LF 二重変換を防ぐため、cfmakeraw で初期化。
