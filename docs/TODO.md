# dock-code TODO

## 1. セッション永続化 & マルチデバイス同期

### 1-1. tmux 統合（リモート側セッション永続化）
- SSH/DevContainer 接続時に tmux セッションを自動作成
- 再接続時に既存 tmux セッションへ自動 attach
- PaneContainer のペイン構成と tmux ウィンドウ/ペインの対応付け
- tmux セッション名にプロジェクト ID を含めて一意に管理

### 1-2. アカウントベースの状態保存（クライアント側）
- プロジェクト構成（接続先、ペインレイアウト、開いているファイル等）をアカウントに紐づけて保存
- Settings Sync の仕組みを拡張 or 独自のクラウド同期レイヤー
- 別デバイスで開いた際にプロジェクト一覧と接続先が復元される
- ローカル状態 vs リモート状態の分離（リモートは tmux 側が持つ）

### 1-3. マルチデバイスワークフロー
- デバイス A で作業 → デバイス B で開く → 同じ SSH 先に再接続 → tmux attach でセッション復元
- アプリ再起動時も同様のフロー
- コンフリクト回避：同一セッションへの同時接続の扱い

## 2. レイアウト構造

### 2-1. Title Bar / Status Bar をワークベンチ側に寄せる
- 現状: Title Bar と Status Bar がアプリ全幅に跨っている（PaneContainer の上下にも）
- 目標: ワークベンチ（ActivityBar + Sidebar + Editor）の内側に閉じる
- PaneContainer / ProjectBar はフル高さで表示
- macOS トラフィックライトの位置に注意

### 2-2. アプリ全体のヘッダー/フッター（将来）
- 内容は運用しながら検討
- Status Bar の SSH/DevContainer 接続情報（左下）はプロジェクト単位の情報
  - マルチプロジェクト時: 各プロジェクトの接続状態をどこに表示するか
  - アプリ全体フッター vs ワークベンチ内 Status Bar の役割分担

## 3. エージェント連携（Claude Code / Codex / Gemini CLI 等）

### 3-1. エージェント状態の監視
- ターミナル出力を解析してエージェントの状態を検知（実行中/待機中/完了/エラー/入力待ち）
- ProjectBar の各プロジェクトアイコンにステータスインジケーター表示
  - 例: 緑スピナー=実行中、黄色=入力待ち、緑チェック=完了、赤=エラー
- 複数プロジェクトで複数エージェントが並列実行している状態を一覧把握

### 3-2. 通知システム
- エージェントの状態変化時にデスクトップ通知/アプリ内通知
  - 完了、エラー、入力待ち（ユーザーの対応が必要）などをトリガーに
- 通知クリック → 該当プロジェクトに切り替え → 該当ターミナルにフォーカス
- 通知の優先度/フィルタリング（全完了通知は不要、エラーのみ等）

### 3-3. ファイル監視 & エディタ連携
- エージェントがファイルを編集したとき、VS Code エディタで自動的にそのファイルを開く/更新する
- diff ビューでリアルタイムに変更内容を表示
- 「追従モード」: エージェントが触っているファイルを自動で追いかける

### 3-4. ナビゲーション連携
- エージェントから VS Code に「このファイルのこの行を開いて」と指示できる
- `file:line:column` 形式で IEditorService.openEditor() を呼ぶブリッジ
- エージェント出力内の `file_path:line_number` パターンをクリッカブルにする

### 3-5. 実装アプローチ
- ターミナル `onProcessData` を監視して状態検知（プロンプト復帰=完了、エラーパターン等）
- Claude Code の IDE hooks / `--ide-protocol` を活用（NeoVim 統合と同等）
- PaneContainer 内ターミナルと VS Code ワークベンチ間は同一プロセスなので直接呼び出し可能
- エージェントごとの状態検知ルールを抽象化（Claude Code / Codex / Gemini で出力パターンが異なる）

## 4. キーボードショートカット（tmux 互換）

### ステータス: ✅ 基本実装済

**実装済み (prefix: Ctrl+A):**
- [x] ペイン間方向移動 (Ctrl+A, ↑↓←→) — PaneContainer 内 + ワークベンチ境界越え
- [x] ペイン分割 (Ctrl+A, " / %) — 水平/垂直
- [x] ペイン閉じる (Ctrl+A, x)
- [x] ペインズーム (Ctrl+A, z)
- [x] プロジェクト切替 (Ctrl+A, n/p / Ctrl+A, 1-9 / Cmd+1-9)
- [x] プロジェクトクイックピッカー (Ctrl+A, w)
- [x] エリア循環移動 (Ctrl+; / Ctrl+') — ペイン + エディタ全域
- [x] フォーカス切替 (Ctrl+A, Tab) — PaneContainer ↔ エディタ
- [x] フォーカス移動時のグローアニメーション

### 未実装
- [ ] ペインのリサイズ（幅/高さ調整）
- [ ] 前回フォーカスしていたペイン/エディタに戻る

## 5. レイアウト制約

### 5-1. VS Code ワークベンチ側の最小幅問題
- 現状: VS Code 側（ActivityBar+Sidebar+Editor）の合計 minimumWidth が大きく、PaneContainer 側を広げられない
- ワークベンチ Grid の各 Part の minimumWidth が合算されるため、ウィンドウの半分以上を VS Code 側が占有
- 対処案: Editor の minimumWidth 調整、Sidebar 非表示時の連動、Phase 3 のペイン化で根本解決

## 6. PaneContainer

### 6-1. 基盤改善
- ターミナル初回レンダリングのタイミング調整（非同期 createTerminal の完了待ち）
- コンテキストメニュー（右クリックで Split Down / Split Right / Close）
- ペインタイプ選択 UI（新規ペイン作成時にターミナル/Chat/Browser 等を選択）

### 6-2. 新コンテンツタイプ
- Chat ペイン（AI チャット UI）
- Browser ペイン（組み込みブラウザ）
- その他（ログビューア、ドキュメントプレビュー等）

### 6-3. Phase 3: ワークベンチのペイン化
- VS Code ワークベンチ全体（ActivityBar + Sidebar + Editor）を1つのペインとして扱えるようにする
- PaneContainer がトップレベルになり、ワークベンチも1ペインとして配置
- 複数ワークベンチの並列表示も可能に

## 7. プロジェクトシステム

### 7-1. ProjectBar UI
- ドラッグ&ドロップでプロジェクト並び替え
- プロジェクトごとのステータス表示（接続中/切断/エラー等）
- プロジェクトのグルーピング

### 7-2. プロジェクト状態管理
- エディタタブ、ターミナル、ワークスペースフォルダの保存・復元（ProjectStateSwitcher の完成）
- プロジェクト切り替え時のスムーズなトランジション

## 8. DevContainer / SSH 連携

### ステータス: SSH ✅ 動作確認済 / DevContainer ✅ 基本動作確認済

### 実装済み

**SSH (`extensions/dock-code-remote-ssh/`)**
- 自前の `RemoteAuthorityResolver` で `ssh-remote` を解決
- システム `ssh` コマンドで接続、`~/.ssh/config` ホスト一覧表示
- REH サーバーを GitHub Release からリモートにダウンロード・起動
- SSH トンネル（TCP 接続確認付き）
- プロジェクトシステム統合（新ウィンドウではなくプロジェクト内で開く）
- 起動時の自動復元

**DevContainer (`extensions/dock-code-remote-containers/`)**
- SSH 先で `devcontainer up` → コンテナ起動
- コンテナ内に REH サーバーをインストール（GitHub Release から）
- socat ポートリレー + SSH トンネル
- devcontainer.json 自動検出 → 「Reopen in Container」通知
- 「Reopen without Container」で SSH に戻る
- リモートフォルダブラウザ UI

**REH ビルド CI (`.github/workflows/build-reh.yml`)**
- GitHub Actions で Linux 上でビルド → Release に自動公開
- linux-x64 / linux-arm64 対応
- ネイティブモジュール（node-pty, @parcel/watcher）が正しいバイナリで含まれる

### 次にやること

- [x] DevContainer 接続時にマウント済みワークスペースフォルダを自動で開く（ループせずに）
- [ ] SSH 接続断時の自動再接続
- [ ] プロジェクト作成 UI に SSH/DevContainer 設定を統合
- [ ] `.vscode` の色設定が ProjectBar/PaneContainer に波及する問題の修正
- [ ] tmux 統合（1-1 と連携）
