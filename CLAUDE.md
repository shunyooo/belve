# CLAUDE.md

## Belve とは

macOS ネイティブ（Swift/SwiftUI）のマルチプロジェクト開発環境。SSH/DevContainer リモート接続、ターミナル、コードエディタ、Markdown WYSIWYG を統合。

## ドキュメント

- [docs/TODO.md](docs/TODO.md) — タスク一覧・ロードマップ
- [docs/architecture.md](docs/architecture.md) — アーキテクチャ設計
- [docs/DESIGN.md](docs/DESIGN.md) — デザイン方針
- [docs/development-guide.md](docs/development-guide.md) — 開発ガイド（セットアップ、スクショ、ワークフロー、ショートカット）

## ビルドと開発

```bash
# ビルド（.app バンドル作成）
./scripts/build-app.sh

# クリーンビルド（キャッシュ問題の疑いがある場合は必ずこちら）
swift package clean && ./scripts/build-app.sh

# 起動（.app バンドル経由。キーボード入力に必須）
pkill -f 'MacOS/Belve$' 2>/dev/null; open Belve.app

# プロセス停止
pkill -f 'MacOS/Belve$' 2>/dev/null

# xterm.js バンドル再生成（scripts/terminal-entry.js 変更時に必要）
npx esbuild scripts/terminal-entry.js --bundle --format=iife --outfile=Sources/Belve/Resources/terminal-bundle.js --minify

# belve-persist 変更時は必ず build-persist.sh を使う
# (go build 直接実行だとアプリバンドルに反映されず、deploy_bundle が古いバイナリで上書きする)
./scripts/build-persist.sh

# npm セットアップ（初回 or パッケージ追加時）
npm install

# テスト
swift test
```

### 注意事項

- **必ず `.app` バンドルから起動する** — 生バイナリ実行だと macOS がアプリとして認識せず、キーボードイベントが届かない
- `open .build/.../Belve`（生バイナリを open）は Terminal.app が起動するので使わない
- `.app` バンドルなら `open Belve.app` で OK（Terminal.app は起動しない）
- **ビルドキャッシュに注意** — SPM のインクリメンタルビルドは変更を検知しないことがある。クラッシュが再現し続ける場合は `swift package clean` してからビルドし直すこと。デバッグ前に必ずクリーンビルドで事象を再現確認する

## UI 自動テスト

osascript + screencapture でビルド→起動→スクショ確認→操作テストが可能。

### ビルド → 起動 → スクショ

```bash
# kill → build → 直接実行 → 前面化 → Belve ウィンドウだけスクショ
kill $(pgrep -f '\.build.*Belve') 2>/dev/null
swift build && .build/arm64-apple-macosx/debug/Belve &
sleep 3
osascript -e 'tell app "System Events" to tell process "Belve" to set frontmost to true'
sleep 0.5
WINID=$(swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list { if let o = w[kCGWindowOwnerName as String] as? String, o == "Belve", let id = w[kCGWindowNumber as String] as? Int { print(id); break } }
')
screencapture -l$WINID -x /tmp/belve-ui.png
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

# ウィンドウ位置・サイズ指定
osascript -e 'tell app "System Events" to tell process "Belve" to set position of window 1 to {100, 100}'
osascript -e 'tell app "System Events" to tell process "Belve" to set size of window 1 to {1200, 700}'
```

### 注意事項

- `screencapture -l$WINID` で Belve ウィンドウだけをキャプチャ（他アプリが映り込まない）
- `screencapture -x` は全画面キャプチャ（Ghostty など他アプリも映る。Belve の確認には不向き）
- SPM バイナリは `application "Belve"` では認識されない → `System Events` の `process "Belve"` 経由で操作
- Accessibility 権限がターミナルに必要（System Settings > Privacy & Security > Accessibility）

## アーキテクチャ

詳細は `docs/architecture.md` を参照。

### レイアウト

- **Sidebar**: プロジェクト一覧
- **Command エリア（左）**: ターミナルペイン（縦横グリッド分割可能）
- **Preview エリア（右）**: ファイルツリー + エディタ / Markdown / Web プレビュー

### 技術スタック

- SwiftUI (macOS 14+) — アプリシェル
- xterm.js (WKWebView) — ターミナル描画
- PTYService — プロセス管理（posix_spawn + POSIX_SPAWN_SETSID、raw mode PTY）
- belve-persist (Go) — セッション永続化（dtach ライク、tmux 不要）
- WKWebView + CodeMirror 6 — コードエディタ
- WKWebView + Milkdown — Markdown WYSIWYG
- system `ssh` + PTY — SSH 接続
- `devcontainer` CLI — DevContainer

### プロジェクト構造

```
Sources/Belve/
├── BelveApp.swift          # @main
├── Theme.swift             # カラーパレット・フォント定義
├── Models/
│   └── Project.swift       # プロジェクトデータモデル
├── Views/
│   ├── MainWindow.swift    # ルートレイアウト + TopBar
│   ├── SplitDivider.swift  # ドラッグ可能な分割バー
│   ├── Sidebar/
│   │   └── ProjectListView.swift
│   ├── Command/
│   │   └── CommandArea.swift  # ペインレイアウト + XTermTerminalView
│   └── Preview/
│       └── PreviewArea.swift
├── Terminal/
│   ├── XTermTerminalView.swift       # xterm.js WKWebView ラッパー
│   └── LauncherScriptGenerator.swift # シェル起動スクリプト生成
├── Services/
│   ├── PTYService.swift              # PTY 生成・管理（raw mode）
│   └── AgentNotificationTransport.swift  # OSC エージェント通知
└── Resources/
    ├── bin/                 # belve CLI, claude wrapper, belve-persist バイナリ
    ├── terminal.html        # xterm.js ホスト HTML
    ├── terminal-bundle.js   # esbuild バンドル
    └── xterm.css

tools/belve-persist/         # Go 製セッション永続化ツール
├── main.go                  # マスター + クライアント (auto-attach)
├── pty_linux.go / pty_darwin.go    # PTY 操作（OS別）
└── term_linux.go / term_darwin.go  # ターミナル設定（OS別）
```

### 既知の問題

- エディタ表示時にサイドバーとターミナル間に空白エリアが出る（レイアウト計算の問題）
- **PTYService は raw mode** — belve-persist との PTY 2段重ねで CR/LF 二重変換を防ぐため `cfmakeraw` で初期化。これが前提なので変更注意

## 設計原則

- 1ファイル1責務（凝縮度優先。行数制限なし、責務が混在していれば分割）
- Protocol 駆動（Service 層は Protocol で定義）
- DI はイニシャライザ注入
- View は `*View`、Service は `*Service`

## コーディング規約

- インデントはタブ
- Swift naming conventions（PascalCase: 型、camelCase: 変数/関数）
- デバッグログ（`NSLog("[Belve] ...")`）は残してよい

## 実装後レビュー（サブエージェント）

実装タスクを完了する前に、以下の2つのレビューをサブエージェント（Agent ツール）で実行する。両方 PASS するまで修正を繰り返すこと。

### 1. Plan Review（プラン適合性チェック）

プランや要件に対して実装が正しく完了しているかを検証する。

```
Agent ツールで起動（subagent_type: general-purpose）:
- git diff で変更内容を取得
- 会話のプラン/要件と照合
- 未実装ステップ、意図からの逸脱、スコープクリープを検出
- 詳細は .claude/skills/review-plan.md を参照
```

**起動タイミング**: プランに基づく実装が一通り完了した時点

### 2. Rules Review（プロジェクトルールチェック）

変更ファイルがプロジェクトの設計原則・規約に準拠しているかを検証する。

```
Agent ツールで起動（subagent_type: general-purpose）:
- git diff --name-only で変更ファイルを特定
- 各ファイルを読み込み、ルール違反を検出
- 凝縮度・構造（単一責務、レイヤー漏洩）、設計（Protocol 駆動、DI）、スレッド・パフォーマンス、規約（タブ、命名）、安全性、テスト品質をチェック
- 詳細は .claude/skills/review-rules.md を参照
```

**起動タイミング**: 全ての実装変更が完了した時点（Plan Review の後）

### レビューフロー

```
実装完了
  ↓
Plan Review（サブエージェント）
  ↓ FAIL → 修正 → 再レビュー
  ↓ PASS
Rules Review（サブエージェント）
  ↓ FAIL → 修正 → 再レビュー
  ↓ PASS
ユーザーに完了報告
```
