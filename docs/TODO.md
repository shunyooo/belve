# Belve TODO

## 緊急: 起動時にターミナルが空になる

`keybind = clear` を Ghostty config に入れたことが原因の可能性。Ghostty のデフォルトキーバインドを全無効化したことで、ターミナル起動に必要な内部処理も無効になった可能性がある。

**調査方針:**
- `keybind = clear` を外して起動するか確認
- 必要なキーバインドだけ個別に無効化する方式に変更
- もしくは Ghostty config の `keybind = unbind` で特定のバインドだけ無効化

## 直近の優先タスク

### ターミナル (GhosttyKit)
- [x] クリップボード対応（コピー & ペースト）— GhosttyKit 内蔵で動作確認済み
- [x] テキスト選択（マウスドラッグ、ダブルクリック単語選択、トリプルクリック行選択）— GhosttyKit 内蔵で動作確認済み
- [ ] **ペイン split 時に元のターミナルが再初期化される問題** — NSView キャッシュで対処中だが完全ではない。根本的には Ghostty surface を安全に破棄/移動する仕組みが必要
- [ ] **Ghostty surface の安全な破棄** — deinit でクラッシュする。`keybind = clear` で Ghostty のデフォルトアクションを無効化したが、ターミナルが空になる副作用が発生
- [ ] URL リンク検出 & Cmd+クリックでブラウザオープン
- [ ] スクロールバー表示（フェード付き）
- [ ] Ghostty config のユーザーカスタマイズ対応（フォント、テーマ等）
- [x] GhosttyKit.xcframework のダウンロードスクリプト（`scripts/setup.sh`）
- [x] IME 入力の位置制御 — GhosttyKit 内蔵

### Cmd ショートカットと Ghostty の衝突
Ghostty のデフォルトキーバインド（Cmd+D=split, Cmd+W=close, Cmd+1-9=tab switch 等）が
Belve の SwiftUI ショートカットと衝突してクラッシュする。

**解決済み:**
- `performKeyEquivalent` で Cmd キーを Ghostty に渡さない (`return false`)
- `keyUp` で Cmd キーを Ghostty に渡さない
- SwiftUI `CommandGroup` → `.onKeyPress` に移行（CommandGroup 内の NotificationCenter.post が performKeyEquivalent コールスタック内で @Published 変更を引き起こしクラッシュ）
- `keybind = clear` で Ghostty のデフォルトバインド全無効化 → **副作用: ターミナルが空になる**

**未解決:**
- `keybind = clear` の副作用を回避しつつ、Ghostty のデフォルトバインドを無効化する方法

### エージェント連携
- [ ] SSH/DevContainer でのエージェントイベントリレー（`ssh tail -f` 方式の Swift 実装）
- [x] デスクトップ通知（`UserNotifications` framework）— waiting 遷移時にバナー+サウンド
- [x] 通知クリック → プロジェクト切替 + ペインフォーカス
- [x] セッションラベル自動生成（Claude Code の初回プロンプトから TopBar に表示）
- [ ] ゾンビセッション自動クリーンアップ（タイムアウトベース）

### レイアウト & UI
- [x] ペイン分割 (Cmd+D / Cmd+Shift+D)
- [x] ペインサイズのドラッグリサイズ（比率ベース、PaneDivider コンポーネント）
- [x] ペイン閉じる (Cmd+W)
- [ ] ペイン状態の永続化（分割構成を再起動後も保持）
- [x] サイドバーの折りたたみ / 展開（アニメーション付き）
- [x] TopBar に接続状態バッジ（SSH/DevContainer/Local）
- [x] DevContainer 検出バナー（右下）
- [x] プロジェクト右クリックコンテキストメニュー（Rename/Delete）
- [ ] `Cmd+'` でアプリ表示/非表示トグル（グローバルホットキー）— 実装済みだが動作未確認

### キーボードショートカット
- [x] プロジェクト切替 (Cmd+1-9) — `.onKeyPress` で実装
- [x] ペイン分割 (Cmd+D / Cmd+Shift+D) — `.onKeyPress` で実装
- [x] ペイン閉じる (Cmd+W) — `.onKeyPress` で実装
- [x] コマンドパレット (Cmd+Shift+P)
- [x] フォルダブラウザ (Cmd+O)
- [ ] tmux 互換 prefix (Ctrl+A) — ペイン移動/分割/閉じる/ズーム
- [ ] エリア循環移動 (Option+;/')

## 中期タスク

### SSH / DevContainer
- [x] SSH ControlMaster で接続多重化（2本目以降は瞬時接続）
- [x] tmux 統合（SSH/DevContainer/ローカル全対応、mouse on + extended-keys）
- [x] SSH 切断後にローカルシェルにフォールバック（exec → 非 exec）
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
- [ ] メディアプレビュー改善

## 実装済み

### ターミナル
- [x] GhosttyKit ベースのターミナル描画（Metal GPU レンダリング）
- [x] キーボード入力、マウス、スクロール
- [x] リサイズ + rewrap
- [x] シェル汎用 PATH 注入（ZDOTDIR for zsh, --rcfile for bash, --init-command for fish）
- [x] ANSI カラーパレット（One Dark 風）
- [x] `sendText` メソッド（キーイベント変換付き、`\n` → Enter キー）
- [x] ペイン分割時の NSView キャッシュ（元ペインの再初期化回避）

### エージェント連携
- [x] ファイルベースのエージェントイベント監視（`/tmp/belve-agent-events`）
- [x] Claude Code hooks 自動注入（`claude` wrapper + `belve claude-hook`）
- [x] ProjectListView のステータスドット表示（running=青, waiting=黄, completed=緑）
- [x] paneId → projectId マッピング
- [x] デスクトップ通知（UserNotifications framework）
- [x] 通知クリック → プロジェクト切替

### アプリ基盤
- [x] macOS ネイティブ SwiftUI アプリ
- [x] マルチプロジェクト管理（サイドバー）
- [x] プロジェクト切替で接続維持（opacity ベース表示切替、surface 破棄なし）
- [x] ペイン分割（縦横グリッド、ドラッグリサイズ）
- [x] コマンドパレット
- [x] フォルダブラウザ (Cmd+O、Tab でフォルダ移動、Enter で確定)
- [x] SSH / DevContainer 接続
- [x] SSH ControlMaster 多重化
- [x] tmux 統合
- [x] TopBar 接続状態バッジ
- [x] クラッシュシグナルハンドラ
- [x] バイナリ日時ログ（ビルドキャッシュ検証用）

### 設計上の注意
- **Ghostty surface は安全に破棄できない** — deinit/free でクラッシュ。プロジェクト切替は opacity で対応。
- **SwiftUI CommandGroup + @Published = クラッシュ** — performKeyEquivalent のコールスタック内で @Published 変更すると EXC_BAD_ACCESS。`.onKeyPress` を使う。
- **SPM ビルドキャッシュ** — インクリメンタルビルドが変更を反映しないことがある。`swift package clean` + `rm -rf .build` でフルリビルドが必要。
- **Ghostty `keybind = clear`** — デフォルトバインド全無効化でクラッシュ防止できるが、ターミナルが空になる副作用あり。
