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

### ステータス: ✅ 基本レイアウト改善済

**実装済み:**
- [x] VS Code エリアの最小幅を大幅削減（Editor 220→50px, Sidebar 170→50px, PaneContainer 200→100px）
- [x] PaneContainer の maximumWidth 制限撤廃（800px→無制限）
- [x] PaneContainer サイズの永続化（`LayoutStateKeys.PANECONTAINER_SIZE`）
- [x] デフォルト PaneContainer サイズをウィンドウ幅の 1/3 に設定
- [x] ウィンドウリサイズ時の比率維持（`proportionalLayout: true`）
- [x] ターミナルペインのサイズ修正（`position: absolute; inset: 0` で xterm layout と干渉しない）
- [x] ターミナル作成後の pending layout 適用（非同期 createTerminal の完了待ち）

### 未実装
- [ ] Title Bar / Status Bar をワークベンチ側に寄せる
  - 現状: Title Bar と Status Bar がアプリ全幅に跨っている（PaneContainer の上下にも）
  - 目標: ワークベンチ（ActivityBar + Sidebar + Editor）の内側に閉じる
  - PaneContainer / ProjectBar はフル高さで表示
  - macOS トラフィックライトの位置に注意
- [ ] アプリ全体のヘッダー/フッター設計

## 3. エージェント連携（Claude Code / Codex / Gemini CLI 等）

### ステータス: ✅ 基本実装済（Claude Code hooks ベース）

**実装済み:**

#### 3-1. エージェント状態の監視 ✅
- [x] Claude Code hooks による状態検知（`/tmp/dock-code-agent-events` JSONL ファイル監視）
- [x] `AgentEventMonitor`（main process）がイベントファイルを `fs.watch()` で監視
- [x] セッションごとのステータス追跡（`ProjectSessionTracker`）
  - 複数セッション並列実行時: 優先度ベースの aggregate（running > waiting > error > completed > idle）
  - セッション一覧を `IAgentSession[]` として ProjectBar に提供
- [x] `ProjectStatus` enum 拡張: `Idle`, `Running`, `Waiting`, `Completed`, `Error`
- [x] `IAgentSession` インターフェース + `updateAgentSessions` IPC メソッド

#### 3-1a. hooks 自動設定 ✅
- [x] `AgentHooksSetup`: dock-code 起動時に `~/.claude/settings.json` に hooks を自動追加
- [x] hooks コマンドは inline node スクリプト（外部ファイル不要、Docker コンテナ内でも動作）
- [x] リモートホストへの hooks 設定: SSH 経由で `~/.claude/settings.json` を更新
- [x] Docker コンテナ内への settings.json 同期（file-level bind mount の inode 問題対策）
- [x] hooks マーカー（`dock-code-agent-events`）による重複登録防止

#### 3-1b. リモートイベントリレー ✅
- [x] SSH/DevContainer プロジェクトを `folderUri` の authority から自動検出
- [x] SSH `tail -f` でリモートのイベントファイルをローカルに中継
- [x] DevContainer: SSH ホスト + 全 running コンテナの `/tmp/dock-code-agent-events` を並列 tail
- [x] 自動再接続（切断時 5 秒後にリトライ）
- [x] イベントファイル内の `projectPath` → `folderUri` マッチング（フォールバック: アクティブプロジェクト）

#### 3-1c. ProjectBar ステータス表示 ✅
- [x] 各プロジェクトの下にセッションごとのステータスドット表示
  - Running: オレンジ + パルスアニメーション
  - Waiting: オレンジ（静止）
  - Completed: 緑
  - Error: 赤
- [x] 展開モードではステータスラベルも表示（「Running」「Done」等）
- [x] `onDidChangeProjects` イベントで ProjectBar 自動更新

**イベントフロー:**
```
Claude Code hooks → /tmp/dock-code-agent-events (JSONL)
  ↓ (ローカル: fs.watch)
  ↓ (リモート: ssh tail -f → ローカルファイルに append)
AgentEventMonitor.readNewEvents()
  → handleEvent() → ProjectSessionTracker.update()
  → projectService.updateProjectStatus() + updateAgentSessions()
  → onDidChangeProjects → ProjectBar.renderContent()
```

**イベント JSON 形式:**
```json
{
  "source": "terminal",
  "eventType": "claude-code",
  "status": "running|completed|waiting|session_start|session_end",
  "projectPath": "/path/to/project",
  "sessionId": "uuid",
  "message": "Generating|Done|notification|start|end"
}
```

**関連ファイル:**
- `src/vs/platform/projects/electron-main/agentEventMonitor.ts` — イベント監視 + リモートリレー
- `src/vs/platform/projects/electron-main/agentHooksSetup.ts` — hooks 自動設定
- `src/vs/platform/projects/common/projects.ts` — `ProjectStatus`, `IAgentSession`
- `src/vs/workbench/browser/parts/projectbar/projectBarPart.ts` — ステータス表示 UI
- `scripts/dock-code-agent-hook` — スタンドアロン hook スクリプト（参考実装）

### 未実装

#### 3-2. 通知システム ✅
- [x] エージェントの状態変化時にデスクトップ通知（Electron Notification API）
  - Completed, Error, Waiting への遷移で発火
  - ウィンドウフォーカス中 + アクティブプロジェクト → 抑制
  - Error/Waiting は音あり、Completed は silent
- [x] 通知クリック → 該当プロジェクトに切り替え → PaneContainer ターミナルにフォーカス
  - `onDidRequestPaneContainerFocus` IPC イベントで main→renderer フォーカス要求
- [ ] 通知の優先度/フィルタリング設定 UI（全完了通知は不要、エラーのみ等）

#### 3-3. ファイル監視 & エディタ連携
- [ ] エージェントがファイルを編集したとき、VS Code エディタで自動的にそのファイルを開く/更新する
- [ ] diff ビューでリアルタイムに変更内容を表示
- [ ] 「追従モード」: エージェントが触っているファイルを自動で追いかける

#### 3-4. ナビゲーション連携
- [ ] エージェントから VS Code に「このファイルのこの行を開いて」と指示できる
- [ ] `file:line:column` 形式で IEditorService.openEditor() を呼ぶブリッジ
- [ ] エージェント出力内の `file_path:line_number` パターンをクリッカブルにする

## 4. キーボードショートカット（tmux 互換）

### ステータス: ✅ 基本実装済

**設計方針:**
- キーバインド定義はファイル上部の `keybindings` オブジェクトに集約（データドリブン）
- ユーザーは VS Code の `keybindings.json` でコマンド ID を使ってオーバーライド可能
- 定義ファイル: `src/vs/workbench/contrib/projects/browser/dockCodeKeybindings.ts`

**実装済み:**

#### Prefix 系 (Ctrl+A → key):
| キー | コマンド ID | 操作 |
|------|-----------|------|
| `Ctrl+A, ↑` | `dockcode.pane.focusUp` | 上ペインへ移動（ワークベンチ境界越え） |
| `Ctrl+A, ↓` | `dockcode.pane.focusDown` | 下ペインへ移動 |
| `Ctrl+A, ←` | `dockcode.pane.focusLeft` | 左へ移動（Workbench → PaneContainer） |
| `Ctrl+A, →` | `dockcode.pane.focusRight` | 右へ移動（PaneContainer → Workbench） |
| `Ctrl+A, "` | `dockcode.pane.splitDown` | ペイン下分割 |
| `Ctrl+A, %` | `dockcode.pane.splitRight` | ペイン右分割 |
| `Ctrl+A, x` | `dockcode.pane.close` | アクティブペイン閉じる |
| `Ctrl+A, z` | `dockcode.pane.toggleZoom` | ペインズーム切替 |
| `Ctrl+A, n` | `dockcode.project.next` | 次のプロジェクト |
| `Ctrl+A, p` | `dockcode.project.previous` | 前のプロジェクト |
| `Ctrl+A, 1-9` | `dockcode.project.switchTo1-9` | プロジェクト番号切替 |
| `Ctrl+A, w` | `dockcode.project.quickPick` | プロジェクトクイックピッカー |
| `Ctrl+A, Tab` | `dockcode.focus.cycle` | PaneContainer ↔ エディタ切替 |

#### ダイレクト系:
| キー | コマンド ID | 操作 |
|------|-----------|------|
| `Option+;` | `dockcode.pane.focusPrev` | 前のエリアへ循環（ペイン + エディタ全域） |
| `Option+'` | `dockcode.pane.focusNext` | 次のエリアへ循環 |
| `Cmd+1-9` | `dockcode.project.quick1-9` | プロジェクト即切替 |

**方向ナビゲーション詳細:**
- PaneContainer 内: ペイン間を方向キーで移動
- PaneContainer 右端で `→`: Workbench エディタにフォーカス移動
- Workbench で `←`: PaneContainer にフォーカス移動
- フォーカス移動時にグローアニメーション（CSS `dockcode-focus-pulse`）

**エリア循環詳細:**
- 順序: [ペイン0] → [ペイン1] → ... → [エディタ] → [ペイン0] → ...
- Welcome ページ等の webview エディタでも動作（`blur()` + `requestAnimationFrame` で対応）

**関連ファイル:**
- `src/vs/workbench/contrib/projects/browser/dockCodeKeybindings.ts` — 全キーバインド定義 + コマンド登録
- `src/vs/workbench/services/paneContainer/common/paneContainerService.ts` — `PaneDirection` enum, `IPaneContainerService`
- `src/vs/workbench/browser/parts/paneContainer/paneContainerPart.ts` — ペインナビゲーション実装
- `src/vs/workbench/browser/parts/paneContainer/paneView.ts` — フォーカス追跡 + グローアニメーション
- `src/vs/workbench/browser/parts/paneContainer/media/paneContainer.css` — グローアニメーション CSS

### 未実装
- [ ] ペインのリサイズ（幅/高さ調整）キーバインド
- [ ] 前回フォーカスしていたペイン/エディタに戻る

## 5. レイアウト制約

### ステータス: ✅ 解決済

- [x] VS Code ワークベンチ側の最小幅問題
  - Editor minimumWidth: 220→50px
  - Sidebar minimumWidth: 170→50px
  - PaneContainer minimumWidth: 200→100px
  - 合計最小幅: ~296px（以前は ~600px 以上）

## 6. PaneContainer

### 6-1. 基盤改善
- [x] ターミナル初回レンダリングのタイミング調整（pending layout 適用）
- [ ] コンテキストメニュー（右クリックで Split Down / Split Right / Close）
- [ ] ペインタイプ選択 UI（新規ペイン作成時にターミナル/Chat/Browser 等を選択）

### 6-2. 新コンテンツタイプ
- [ ] Chat ペイン（AI チャット UI）
- [ ] Browser ペイン（組み込みブラウザ）
- [ ] その他（ログビューア、ドキュメントプレビュー等）

### 6-3. Phase 3: ワークベンチのペイン化
- [ ] VS Code ワークベンチ全体（ActivityBar + Sidebar + Editor）を1つのペインとして扱えるようにする
- [ ] PaneContainer がトップレベルになり、ワークベンチも1ペインとして配置
- [ ] 複数ワークベンチの並列表示も可能に

## 7. プロジェクトシステム

### 7-1. ProjectBar UI
- [ ] ドラッグ&ドロップでプロジェクト並び替え
- [x] プロジェクトごとのステータス表示（エージェントセッション状態）
- [ ] プロジェクトのグルーピング

### 7-2. プロジェクト状態管理
- [x] プロジェクト切替時のフォーカス復元（メインウィンドウ復帰時の webContents.focus()）
- [ ] エディタタブ、ターミナル、ワークスペースフォルダの保存・復元（ProjectStateSwitcher の完成）
- [ ] プロジェクト切り替え時のスムーズなトランジション

## 8. DevContainer / SSH 連携

### ステータス: SSH ✅ 動作確認済 / DevContainer ✅ 動作確認済

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
- [x] 接続時にマウント済みワークスペースフォルダを自動で開く（接続キャッシュ + deferred openFolder でループ防止）
- [x] キャッシュ再利用時もワークスペースフォルダを正しく開く（`scheduleWorkspaceFolderOpen` 共通化）

**REH ビルド CI (`.github/workflows/build-reh.yml`)**
- GitHub Actions で Linux 上でビルド → Release に自動公開
- linux-x64 / linux-arm64 対応
- ネイティブモジュール（node-pty, @parcel/watcher）が正しいバイナリで含まれる

### 次にやること

- [ ] SSH 接続断時の自動再接続
- [ ] プロジェクト作成 UI に SSH/DevContainer 設定を統合
- [ ] `.vscode` の色設定が ProjectBar/PaneContainer に波及する問題の修正
- [ ] tmux 統合（1-1 と連携）

## 9. ビルド & 開発環境

### ステータス: ✅ 整備済

**実装済み:**
- [x] dock-code 独自拡張の依存を `build/npm/dirs.ts` に追加（`npm install` で自動インストール）
- [x] dock-code 独自拡張のコンパイルを `build/gulpfile.extensions.ts` に追加（`gulp compile-extensions` で自動）
- [x] esbuild transpile 時に `codicon.ttf` を自動コピー（`build/next/index.ts`）
- [x] CLAUDE.md に初回セットアップ手順を記載
- [x] Node.js 22.22.1 を Volta で pin（`package.json`）
- [x] VS Code 設定/拡張インポートスクリプト（`scripts/import-vscode-settings.sh`）
  - Microsoft Remote 系拡張のブロックリスト付き
  - `--settings-only` / `--extensions-only` オプション
- [x] デバッグログは基本残す方針（ログレベルで制御）
