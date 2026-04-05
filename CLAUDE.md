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

# 起動（.app バンドル経由。キーボード入力に必須）
kill $(pgrep -f Belve) 2>/dev/null; open Belve.app

# プロセス停止
kill $(pgrep -f Belve) 2>/dev/null

# テスト
swift test
```

### 注意事項

- **必ず `.app` バンドルから起動する** — 生バイナリ実行だと macOS がアプリとして認識せず、キーボードイベントが届かない
- `open .build/.../Belve`（生バイナリを open）は Terminal.app が起動するので使わない
- `.app` バンドルなら `open Belve.app` で OK（Terminal.app は起動しない）

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
- SwiftTerm (TerminalView) — ターミナル描画（NSViewRepresentable）
- PTYService — プロセス管理（posix_spawn + POSIX_SPAWN_SETSID）
- WKWebView + CodeMirror 6 — コードエディタ（未実装）
- WKWebView + Milkdown — Markdown WYSIWYG（未実装）
- system `ssh` + PTY — SSH 接続（未実装）
- `devcontainer` CLI — DevContainer（未実装）

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
│   │   ├── CommandArea.swift
│   │   └── TerminalPaneView.swift  # SwiftTerm + PTYService
│   └── Preview/
│       └── PreviewArea.swift
├── Services/
│   └── PTYService.swift    # PTY 生成・管理（posix_spawn）
└── Resources/              # WebView 用リソース（xterm.js 等）
```

### 既知の問題

- `hiddenTitleBar` と SwiftTerm の組み合わせで Auto Layout クラッシュするため `unifiedCompact` を使用中

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
