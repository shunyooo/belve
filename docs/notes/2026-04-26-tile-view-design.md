# Overview View 実装プラン

プロジェクト横断のターミナル gallery view。複数 project の Claude Code 実行 pane を 1 画面で監視 + 直接操作 + 詳細ビューへ遷移できる。

## 目的 / 動機

- 現状: 1 project = 1 画面、project 切替えで pane を確認するフロー
- やりたいこと: 必要な pane だけを project 跨いで一覧、その場で操作 or 詳細 view へ
- 想定使い方: ターミナルが並んだギャラリーで「どの Claude Code が動いてる/詰まってる」を一望

## 要件 (合意済み)

| | 内容 |
|---|---|
| 表示対象 | フィルタ可能 (デフォルト = Claude Code active)、プロジェクト/グループ単位で絞り込み |
| 密度 | 6-9 medium、pane 数に応じて adaptive grid |
| 入口 | (a) Cmd+Shift+O ショートカット (b) Command palette (c) Sidebar TopBar 上のボタン |
| 操作 | セル内直接入力 + 詳細 view (project) への遷移ボタン |
| 表示要素 | live terminal + StatusIndicator + project/pane 名 |

## 設計の核心 — Pane インスタンス共有

調査で判明した重要事実: 既存の全 pane (`XTermTerminalView`/WKWebView) は `MainWindow` の ZStack で **同時 mount** され、非選択 project は `opacity 0` で隠れてるだけ。破棄されない。

→ Overview view は新規 WKWebView を生成せず、**既存インスタンスを再配置**するだけ。Memory コストはほぼゼロ追加。

実装方法: pane host を MainWindow から `PaneHostRegistry` (Service) に切り出し、`OverviewView` も `projectWorkspace` も同じ registry から NSView を取得。SwiftUI の `NSViewRepresentable` の中で registry が返した NSView をそのまま wrap。

## ファイル変更一覧

### 新規

- `Sources/Belve/Models/ViewMode.swift`
  ```swift
  enum ViewMode: String, Codable { case project, overview }
  ```
- `Sources/Belve/Services/PaneHostRegistry.swift`
  - `[paneId: NSView]` の cache singleton
  - `XTermTerminalView` 起動時に NSView 登録
  - `view(for: paneId)` で取得
- `Sources/Belve/Services/OverviewFilterState.swift`
  - `@Published activeOnly: Bool`, `selectedProjects: Set<UUID>`, `pinnedPanes: Set<UUID>`
  - AppConfig に永続化
- `Sources/Belve/Views/Overview/OverviewView.swift`
  - `LazyVGrid(columns: GridItem(.adaptive(minimum: 280)))`
  - 各セル: 上部 = StatusIndicator + project name + pane title、下 = embedded XTermTerminalView
  - セル click → ViewMode.project + activePaneId set
- `Sources/Belve/Views/Overview/OverviewFilterBar.swift`
  - Segmented control (Active/Waiting/Done/All) + project group dropdown

### 変更

- `Sources/Belve/Services/AppConfig.swift`
  - `viewMode: ViewMode` 追加 + 永続化
  - `OverviewFilterState` 関連フィールド追加
- `Sources/Belve/Views/MainWindow.swift`
  - body root を `Group { switch viewMode { case .project: existing; case .overview: OverviewView() } }`
  - TopBar に view mode toggle button 追加
- `Sources/Belve/Views/Sidebar/ProjectListView.swift`
  - TopBar 下に Overview entry button 追加
- `Sources/Belve/BelveApp.swift`
  - Cmd+Shift+O で `belveToggleOverview` notification post
  - `Notification.Name.belveToggleOverview` 定義
- `Sources/Belve/Views/CommandPaletteView.swift`
  - "Toggle Overview" コマンド追加

## Phase 別タスク

### Phase A — 骨組み (まず動く)

1. ViewMode enum + AppConfig 永続化
2. PaneHostRegistry 実装 (NSView registry)
3. OverviewView 最小版 (固定 grid、全 pane、フィルタなし)
4. MainWindow に view mode 切替 + TopBar toggle
5. セル click → project view + pane focus

### Phase B — 入口とフィルタ

6. Cmd+Shift+O ショートカット + CommandPalette "Toggle Overview"
7. Sidebar TopBar に Overview entry button
8. OverviewFilterBar (Active/Project filter) + 永続化

### Phase C — インタラクション強化

9. セル内入力 (focus 移行 → 既存 xterm に input 流す)
10. "Open in project" hover button + Pin 機能

## リスク / 未解決

### NSView reparenting の SwiftUI 互換性 (要検証)

`NSViewRepresentable.makeNSView` は通常 view 階層ごとに新規生成される。Registry から既存 NSView を返すアプローチが SwiftUI ライフサイクルと喧嘩しないか実装してから確認。

**喧嘩する場合の Plan B**: Overview は live snapshot ではなく定期スクリーンショット (e.g. 1Hz で latestImage 取得 → Image 表示)。入力受付時は project view に瞬時遷移。

### Filter "Claude active" 判定

既存 `AgentSession.status == .running` で判定可能。ただしセッション開始直後の race condition (sessionStart → running の数百ms 間) があれば微 chattering の可能性。

### 多数 pane (15+) 時のレイアウト

`LazyVGrid` で virtualization 効くはずだが、20+ pane で実機確認必要。

## 関連調査メモ

- `XTermTerminalView`: WKWebView ラッパー、Coordinator が PTYService 1:1 保有
- `AgentSession` (NotificationStore.swift:20): projectId, paneId, status, message
- `AgentStatus` enum: idle / sessionStart / running / runningSubagent / waiting / completed / sessionEnd
- `CommandPaletteView`: 既存実装あり、Cmd+Shift+P で toggle
- `BelveApp.swift:32`: keyboardShortcut パターン
- `CommandAreaState.activePaneId`: pane focus の source of truth
- `MainWindow.swift:289` ZStack で全 project workspace を opacity 切替
