# Belve — アーキテクチャ

## Context

Belve は macOS ネイティブ (Swift / SwiftUI) のマルチプロジェクト開発環境。SSH / DevContainer / ローカルを単一ウィンドウで扱い、ターミナル・コードエディタ・ファイルツリー・Markdown WYSIWYG を統合する。

## 技術スタック

| レイヤー | 技術 |
|---|---|
| App Shell / UI | SwiftUI (macOS 14+) |
| ターミナル | xterm.js (WKWebView) + `@xterm/addon-webgl` |
| セッション永続化 | `belve-persist` (Go) — dtach ライクな PTY ブローカー |
| コードエディタ | CodeMirror 6 (WKWebView) |
| Markdown WYSIWYG | Milkdown Crepe (WKWebView) |
| SSH | system `ssh` + ControlMaster + port forward |
| DevContainer | `devcontainer` CLI |
| ビルド | Swift Package Manager + esbuild + go build |

## プロジェクト構造

```
belve/
├── CLAUDE.md                        # AI コンテキスト
├── Package.swift
├── package.json                     # xterm.js バンドル用 (esbuild)
├── Sources/Belve/
│   ├── BelveApp.swift                # @main エントリポイント
│   ├── Theme.swift                   # カラー / フォント / レイアウト定数
│   ├── Models/
│   │   ├── Project.swift
│   │   └── FileItem.swift
│   ├── Views/
│   │   ├── MainWindow.swift
│   │   ├── SplitDivider.swift
│   │   ├── DividerSupport.swift
│   │   ├── LoadingTrack.swift
│   │   ├── SettingsView.swift
│   │   ├── WorkspaceLayoutState.swift
│   │   ├── Sidebar/
│   │   │   └── ProjectListView.swift   # projects + nested agent sessions
│   │   ├── Command/
│   │   │   ├── CommandArea.swift     # ターミナルペインレイアウト
│   │   │   └── DevContainerBanner.swift
│   │   ├── CommandPalette/
│   │   │   ├── CommandPaletteView.swift
│   │   │   └── FolderBrowserView.swift
│   │   └── Preview/
│   │       ├── PreviewArea.swift
│   │       ├── FileTreeView.swift
│   │       ├── FileIconResolver.swift
│   │       ├── CodeEditorView.swift
│   │       ├── MarkdownEditorView.swift
│   │       └── MediaPreviewView.swift
│   ├── Terminal/
│   │   ├── XTermTerminalView.swift        # xterm.js WKWebView ラッパー
│   │   └── LauncherScriptGenerator.swift   # シェル起動スクリプト生成
│   ├── Services/
│   │   ├── ProjectStore.swift          # プロジェクト CRUD / 永続化 / 選択
│   │   ├── WorkspaceProvider.swift     # Local / SSH / DevContainer 抽象
│   │   ├── SSHConfigParser.swift
│   │   ├── SSHTunnelManager.swift      # ControlMaster + port forward 管理
│   │   ├── PTYService.swift            # PTY 生成 (raw mode)
│   │   ├── NotificationStore.swift     # Agent セッション状態
│   │   ├── AgentNotificationTransport.swift  # OSC 9 検知
│   │   └── AppConfig.swift
│   └── Resources/
│       ├── bin/                        # 配布するスクリプト / バイナリ
│       │   ├── belve                   # CLI (hook 受信)
│       │   ├── claude                  # claude ラッパー (hook 注入)
│       │   ├── codex                   # codex ラッパー (同上)
│       │   ├── belve-setup             # リモート側セットアップ
│       │   └── session-bootstrap.sh    # リモート PTY 起動スクリプト
│       ├── terminal.html / editor.html / markdown.html
│       └── *.bundle.js / *.bundle.css  # esbuild 成果物
├── scripts/
│   ├── build-app.sh
│   ├── build-persist.sh
│   ├── terminal-entry.js               # xterm.js バンドル元
│   └── ui-test.sh
├── tools/belve-persist/                # Go 製 PTY 永続化ツール
│   └── main.go
├── WebEditor/                          # CodeMirror 用 npm プロジェクト
└── Tests/BelveTests/
```

## AI エージェントフレンドリーな設計原則

- **1ファイル1責務**: 各 Swift ファイルは凝縮度を優先 (責務が混ざったら分割)
- **Protocol 駆動**: Service 層は Protocol で抽象化し、実装を差し替え可能に
- **明示的な依存**: DI はイニシャライザ注入。グローバル状態を避ける
- **命名規則**: View は `*View`、Service は `*Service`、Model はそのまま

## UI/UX 設計

### レイアウト — Sidebar / Command / Preview

```
┌────────────────────────────────────────────────────┐
│ ┌────┐ ┌──────────────────┬────────────────┐       │
│ │    │ │  Command         │  Preview       │       │
│ │ P  │ │ ┌──────┬───────┐ │ ┌──┐ file-tree │       │
│ │ r  │ │ │Term 1│Term 2 │ │ ├──┘           │       │
│ │ o  │ │ │      │       │ │ │ [main.swift] │       │
│ │ j  │ │ ├──────┴───────┤ │ │ ┌──────────┐ │       │
│ │ e  │ │ │ Terminal 3   │ │ │ │ Editor   │ │       │
│ │ c  │ │ │              │ │ │ └──────────┘ │       │
│ │ t  │ │ │              │ │ │              │       │
│ │ s  │ │ │              │ │ │              │       │
│ └────┘ └──────────────────┴────────────────┘       │
└────────────────────────────────────────────────────┘
```

- **Sidebar (ProjectListView)**: プロジェクト一覧 + 各プロジェクトの下にネストされた Agent セッション。サイドバー切替 Cmd+\、プロジェクト切替 Cmd+[ / Cmd+]、Cmd+1〜9
- **Command エリア**: ターミナルペイン。縦横自由なグリッド分割 (Cmd+D / Cmd+Shift+D)
- **Preview エリア**: ファイルツリー + コードエディタ / Markdown WYSIWYG / メディアプレビュー

### プロジェクトモデル

プロジェクト = 1 つの作業コンテキスト。作成時は名前のみ、接続先は後から設定。

```swift
struct Project {
    let id: UUID
    var name: String
    var workspace: Workspace  // .local | .ssh | .devContainer
}

enum Workspace {
    case local(path: String?)
    case ssh(host: String, path: String?)
    case devContainer(host: String, workspace: String)
}
```

プロジェクトごとに独立したターミナル状態、エディタ状態、ファイルツリーが保持される。切替時は opacity フェードのみ (main エリアはシンプルに、見た目が派手になりすぎないように)。

### コマンドパレット (Cmd+Shift+P)

全操作のエントリポイント:
- `SSH Connect` — `~/.ssh/config` からホスト選択
- `Open Folder` — ローカルフォルダブラウザ
- `Reopen in Container` — devcontainer.json があるとき
- `Split Terminal Vertical` / `Horizontal`
- プロジェクト CRUD 等

### UX 原則

- **キーボードファースト**: すべての主要操作に ショートカット
- **ネイティブ感**: macOS 標準のショートカット遵守、SwiftUI spring アニメーション
- **ミニマル**: 不要な UI 要素は出さない。Typora / Linear のような体験

## リモート接続アーキテクチャ

SSH と DevContainer は共通の port-forward 方式:

```
Mac (Belve.app)                        Remote VM / Container
 ├─ belve-persist (local broker)  ←TCP→ belve-persist (remote broker)
 │   │                                    │
 │   └─ session multiplex                 └─ PTY + shell
 │
 └─ ssh ControlMaster (1 session)         (port forward target)
        │
        └─ -L 192XX:target:19222
```

- **1 ホストあたり SSH セッション 1 本** — ペイン数に関係なく `sshd MaxSessions` を消費しない
- **セッション名で多重化** — 各ペインは独立した PTY を持つが同じ TCP トンネルを共有
- **切断耐性** — `belve-persist` が PTY を維持するので、Mac 側切断・再接続で状態は失われない
- DevContainer は broker がコンテナ内 0.0.0.0:19222、plain SSH は VM 側 loopback 19222

詳細は `Sources/Belve/Services/SSHTunnelManager.swift` と `tools/belve-persist/main.go` を参照。
