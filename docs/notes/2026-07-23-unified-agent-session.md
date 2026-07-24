# 統合エージェントセッション実体への再設計（司令塔 P0 の契約）

**更新**: 2026-07-23
**ステータス**: 方向確定・一気にリプレイス実装中（フェーズ分割なし・二経路を残さない cutover）
**前提**: `2026-07-21-agent-cockpit.md`（製品方向）, `2026-05-04-view-as-primary-unit.md`（View 単位化・Phase 1 で停止）, `2026-07-19-tmux-vs-belve-persist.md`（tmux holder 化）
**ブランチ**: `feat/cockpit`

このノートは実装サブエージェントが参照する **契約** である。ここに書かれた不変条件・型・cutover 規則から逸脱しないこと。判断に迷ったらこのノートが優先。

## 1. 問題の核心：同一実体が3回モデリングされ統合されていない

「1エージェントが1タスクをやる場所」という同一の実体が、3つの時代に別々に存在する：

| 時代 | 名前 | 実体 | 状態 |
|---|---|---|---|
| 最古 | **pane** (`paneId`) | ターミナル。`NotificationStore` が状態をここでキー | 現行の識別軸 |
| 2026-05 | **`ProjectView`**（"View"） | 作業文脈の一級単位を狙った | `view.id == projectId` 固定で停止（多 view 未完） |
| 2026-07 | **session**（cockpit） | tmux セッションで走る Claude。司令塔の一級 | 未実装 |

これらを **1つの永続実体 `AgentSession`** に統合する。

## 2. 目標ドメインモデル

```
Project (UUID)
└── AgentSession (1..N)          ← 一級・永続実体。旧 ProjectView + 旧 NotificationStore.AgentSession の統合
    ├── id: SessionKey           ← 安定文字列 = tmux セッション名。これが唯一の識別軸（paneId を置換）
    ├── projectId: UUID
    ├── name: String             ← ユーザー可視名（旧 ProjectView.name / 旧 label）
    ├── state: AgentState        ← 状態は session の属性
    ├── origin: SessionOrigin    ← .launched(Belve 起動) | .discovered(素の tmux→claude を tmux ls で発見)
    ├── startedAt / updatedAt
    └── (workspace: PaneNode tree・editor 状態は SessionKey をキーに既存ストアが保持)
```

### SessionKey（識別軸）
- **型**: `String`。**値 = tmux セッション名**（例 `belve-<uuid8>` や discovered の生名）。
- **canonical な唯一の識別子**。以後 `paneId` を「エージェント/セッションの identity」として使う箇所は全廃し、SessionKey に張り替える。
- pane（`PaneNode` leaf）は SessionKey への **揮発的アタッチ**。main pane は 1 SessionKey に bind。temp pane（ad-hoc shell）は session を持たない。
- **不変条件**: SessionKey は tmux セッション名と 1:1。Belve 起動時は Belve が採番、discovered 時は tmux から取得。paneId から派生させない（旧 `belve-<paneId>` の派生をやめ、SessionKey を session が所有する）。

### AgentState（状態）
```
struct AgentState {
    var status: AgentStatus   // 下記
    var message: String
    var lastActivity: String?
    var currentTool: String?
    var lastUserPrompt: String?
    var subagentCount: Int
}
enum AgentStatus { idle, sessionStart, working, blocked, done, sessionEnd, runningSubagent }
```
- cockpit 語彙へ寄せる：**working**(=旧 running), **blocked**(=旧 waiting), **done**(=旧 completed), **idle**。旧 `sessionStart/sessionEnd/runningSubagent` はライフサイクル/派生として維持。
- 俯瞰・要対応の並び順は **blocked → working → done → idle**（要対応→作業中→完了→待機）。

## 3. ストア構成（cutover 後）

| ストア | 役割 | 変更 |
|---|---|---|
| **`AgentSessionStore`** | セッション実体の唯一の所有者。project→sessions、active session/project、状態更新、永続化、トリアージ集約（要対応数/作業中数、並び順）。 | **`ProjectViewStore` を昇格改修**して新設。多 view API（create/delete/rename/move/setActive）はそのまま session API になる。 |
| **`NotificationService`**（旧 `NotificationStore`） | デスクトップ通知＋未読トリアージリスト（`unreadNotifications`）のみ。**identity/状態は所有しない**。`AgentSessionStore` を読む。 | `sessions`/`agentStatus`/`activeSessionIndex`/`paneToProject` を撤去。`primarySessionPerPane`（重複 claude 抑制）と warm-up 抑制、desktop 通知だけ残す。 |

- **OSC プロデューサ経路**：hook が出す OSC を、端（`XTermTerminalView` の `onAgentStatus`）で **paneId→SessionKey に解決**して `AgentSessionStore.updateState(sessionKey:...)` を呼ぶ。pane は自分の SessionKey を知っている（bind 済み）。
  - 望ましくは hook が SessionKey を直接出す（tmux `#S` を読む）が、初手は端の解決で blast radius を抑える。この判断は実装ユニットで確定し、私が検証する。
- **discovered セッション**：hook が無く OSC を出さない。状態は `tmux ls` 発見＋プロセス/出力観測で **導出**（別ユニット）。これは「主経路失敗→旧経路」ではなく **独立ソースからの導出**であり fallback ではない。

## 4. 旧→新 対応表（実装サブエージェント用）

| 旧（識別/所有） | 新 |
|---|---|
| `PaneNode.paneId` を identity に使う全箇所 | SessionKey に張替（pane は SessionKey へ bind） |
| tmux 名 `belve-<paneId>`（`session-bootstrap.sh`） | tmux 名 = SessionKey（session 所有） |
| belve-persist ソケット名 local=paneIndex / remote=paneShort の**二方式** | SessionKey 由来の**単一方式**に統一 |
| `NotificationStore.sessions/activeSessionIndex/paneToProject/agentStatus[projectId]` | `AgentSessionStore` が SessionKey/projectId で所有 |
| `ProjectView`(`view.id==projectId`) / `ProjectViewStore` | `AgentSession` / `AgentSessionStore`（1 project=N session） |
| `AgentCompanionStore` の `[String:Companion]`（paneId キー） | SessionKey キー |
| `TileView` / `TileFilterState`（paneId・projectId キー） | SessionKey・projectId キー |
| pane-layouts.json / workspace-layout.json（view.id=projectId キー） | SessionKey キー |
| agent-sessions.json / views.json | 統合 `sessions.json`（起動時 1 回 auto-migration、旧 file は `.bak`） |

## 5. 削除対象（container 経路・VT snapshot）

一気に削除する。二経路・feature flag・優しい fallback は残さない（CLAUDE.md 設計原則）。
- **Go (`tools/belve-persist/`)**: `router.go`（mux container routing 一式）, `tunnel.go`（port-forward relay）, `main.go` の TCP broker（`runTCPBroker`/`tcpSession`/replay の broker 側）, `setup.go` の `deployBundle`(docker cp/scp), VT snapshot/serialize-restore に関わる no-replay 特殊経路。**bounded replay(256KB) は残す**。
- **Swift**: `PortForwardManager.swift`, `SSHTunnelManager.swift`, `PaneHostRegistry` の serialize-on-reload（`serializedStates`/`persistSerializedState`/`consumeSerializedState`）と `XTermTerminalView` の `window.terminalRestore`/`BELVE_SKIP_REPLAY` 経路, `DevContainerProvider` の docker cp I/O・`DevContainerBanner`/`RebuildOverlayView`。`Project.isDevContainer` 経路。
- **belve-setup / bin**: container terminfo / `docker exec -e TERM` 注入。
- スコープ判断（どこまで一度に削るか）は実装ユニットで詰め、私が検証する。**先に session 統合を通し、削除は最後のユニット**（動作退行の切り分けを容易にするため）。

## 6. cutover 規則（不変条件）

1. 各ユニット完了時に **`swift build` がグリーン**、かつ**アプリが起動し既存セッションに再接続できる**こと（私が検証）。
2. 二経路を残さない：consumer を新ストアへ移したら、その分の旧 paneId 経路を**同じ変更で削除**。
3. ロールバックは git（branch/revert）。コードに flag を残さない。
4. 永続形式変更は version bump ＋ 1 回限り auto-migration、旧 file は `.bak` 退避。並走（file 2 本）は不可。
5. 実装完了ごとに Plan Review + Rules Review（サブエージェント）を通す（CLAUDE.md）。

## 7. 実装ユニット順序（依存）

1. `AgentSession`/`AgentSessionStore`（土台。OSC 供給を端で SessionKey 解決）＋ SessionKey の tmux/ソケット命名統一
2. サイドバーを session 単位に（project→sessions、detached 表示、要対応セクション）
3. consumer 移行（companion/tile/statusbar/StatusIndicator）＋ `NotificationStore`→`NotificationService` 縮退＋旧 paneId 経路削除
4. `ChangedFilesStore` を PreviewArea「変更/ツリー」トグルに配線
5. discovered セッションの状態導出（`tmux ls`＋プロセス/出力観測）
6. container 経路・VT snapshot 一掃
7. 統合ビルド＋Plan/Rules レビュー＋実機スクショ検証

## 8. 追記（2026-07-25）: workspace 主単位化 と session 昇格ゲート

背骨（識別子一本化・状態所有・container 削除）完了後の設計議論で確定した原則。
§2 の「ProjectView を AgentSession に畳む」は**撤回**し、以下を採用する。

### 8.1 workspace を主単位に（統合ではなく包含）
- 人が「1つの作業」と感じる単位は **agent 単体でも pane 単体でもなく workspace**
  （＝メイン agent ペイン ＋ 0..N 補助ペイン ＋ エディタ/プレビュー状態）。
- 関係は **包含**： `Project ⊃ Workspace(1..N) ⊃ { main pane→AgentSession(SessionKey) にバインド ＋ 補助ペイン ＋ editor }`。
- 理由: 補助ペイン（例「agent が認証を要求→別ペインで shell 認証」）を自然に表現できる。
  workspace を agent に畳むと 1 agent=1 pane に縛られ**表現力が狭まる**ため統合しない。
- `ProjectView`/`ProjectViewStore` は **workspace 層として存置・正式化**（`view.id==projectId`
  スタブと多 workspace 未実装を将来詰める）。`AgentSession` は workspace のメインペインで
  走る agent の**状態**を担う（別実体・SessionKey で参照）。

### 8.2 session 昇格ゲート＝「agent ツールが使われたこと」（元設計の原則を discovery にも適用）
- **tmux/pane が存在するだけでは session ではない。素の端末は端末のまま。**
- **agent ツール（Claude Code / Codex / …）が検出された時に初めて AgentSession として surface**。
  - Claude: `belve` hook の `session_start`（OSC）＝確実。← 元から実装済み（コアは正しい）。
  - 非 Belve / 非 Claude agent（OSC 無し）: **プロセス検出**（`claude`/`codex`/… の小リスト・拡張可）。
- これは新概念ではなく **元の OSC 経路（Claude 専用の agent-gated 表示）を discovery にも揃え、
  マルチ agent に拡張**するもの。Unit 6 の discovery が「`belve-*` tmux 全列挙」になっていた
  のは誤りで、agent 検出ゲートに是正する（補助 shell の idle セッション漏れを解消）。
- 補助ペインは workspace 内の子であり **session ではない**（サイドバー一覧に出さない）。
- 履歴の限界: 「昔 agent が走ったが今 shell」を新規 discovery だけでは判定不能 → live で観測中
  だったものは agent 終了後も done/idle で残す、最初から bare shell のものは surface しない、で許容。
