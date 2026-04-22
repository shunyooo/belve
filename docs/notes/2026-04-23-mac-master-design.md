# Mac master daemon 化 (設計)

作成日: 2026-04-23
ステータス: 設計中

## 背景

現状:
- Belve.app (Swift) が UI + 各種 service (SSHTunnelManager, ProjectStore, RemoteRPCRegistry...) を抱えてる
- pane ごとに bash launcher を spawn → launcher が `ssh host belve-setup` + 接続用 belve-persist を呼ぶ
- N pane 起動 = N 並列の bash + ssh で MaxSessions / FD inheritance / lock stale など bug 量産
- Belve.app クラッシュ時に tunnel teardown + setup state リセット → 再起動が遅い

問題の構造:
- **責務が分散**: Swift / bash launcher / belve-persist (router/broker/daemon) で setup や session 管理がバラバラに分散
- **Belve.app が長命前提の状態を持ってる** が、UI プロセスでもあるので落ちやすい
- bash launcher が「ssh で setup を回す」というのが諸悪の根源

## 採用方針

**Mac 側にも belve-persist の master モードを置き、Belve.app は IPC 経由で master に依頼する形にする。**

- master = `belve-persist -mac-master -socket /tmp/belve-master.sock` (新規モード)
- Belve.app は起動時に master を spawn (or 既存の socket に attach)
- 全ての setup / tunnel / session 操作は master に IPC で投げる
- master は Go の goroutine + sync で per-host / per-project 直列化
- bash launcher は撤廃 (or 接続用 1-line shim だけ残す)

## アーキテクチャ

```
[Mac]
  Belve.app (Swift)
    ├─ MasterClient (NDJSON over Unix socket)
    │     └─ ops: setup / openSession / status / etc.
    ▼
  /tmp/belve-master.sock
    ▲
    │
  belve-persist -mac-master
    ├─ projectSetups: map[uuid]SetupState
    ├─ tunnels:       map[host]*SSHTunnel
    ├─ sessions:      map[sessionID]*LocalDaemon
    └─ goroutines:
         - per-host setup serializer
         - tunnel keep-alive / health check
         - session daemon supervisor

[VM]
  belve-persist -router 127.0.0.1:19200    ← 既存
  belve-persist -tcplisten 127.0.0.1:19223 ← 既存 (plain SSH broker)

[Container]
  belve-persist -tcplisten 0.0.0.0:19222   ← 既存
```

## IPC プロトコル

NDJSON over Unix socket。既存の broker control RPC (`tools/belve-persist/control.go`) と同じ形。

### Ops (master が応答)

| op | params | result | 備考 |
|---|---|---|---|
| `ping` | - | `{ok:true}` | health check |
| `ensureSetup` | `{projectId, host, isDevContainer, workspacePath}` | `{state, error?}` | idempotent。既に done なら即返却。in-progress なら待つ。failed なら error 返す。 |
| `openSession` | `{projectId, paneId, cols, rows}` | `{sessionId, sockPath}` | local daemon が無ければ spawn し attach 用 socket を返す |
| `resizeSession` | `{sessionId, cols, rows}` | `{ok}` | |
| `closeSession` | `{sessionId}` | `{ok}` | |
| `closeProject` | `{projectId}` | `{ok}` | tunnel teardown + sessions 全 close |
| `status` | - | `{projects: [...], tunnels: [...], sessions: [...]}` | UI 表示用 |

### Push (master → Belve.app)

| type | payload | 備考 |
|---|---|---|
| `setupProgress` | `{projectId, state, message?}` | idle/running/ready/failed 遷移時 |
| `sessionExit` | `{sessionId, status}` | PTY 終了 |
| `tunnelHealth` | `{host, healthy}` | tunnel 切断検知 |

## Master の責務

1. **プロジェクト setup の orchestration**:
   - `ensureSetup` を受けたら deploy_bundle + ssh belve-setup を実行
   - per-host で goroutine 直列化 (= MaxSessions 保護)
   - state を保持して idempotent に応答

2. **SSH tunnel 管理**: 既存の `SSHTunnelManager.swift` を移植
   - ControlMaster spawn / persist
   - router forward 確立

3. **セッション管理**: 既存の per-pane local belve-persist daemon を吸収
   - `openSession` で内部の goroutine が PTY broker と接続を確立
   - 各 session の Unix socket を Belve.app に返して、Belve.app は xterm 用に attach
   - Belve.app クラッシュ時も session は master 側で生存

4. **状態の永続化** (任意, phase 2):
   - 起動時に前回の session 一覧を復元できるよう disk に dump

## Belve.app の責務 (master 化後)

- UI 描画
- master との IPC client
- 復元時に master の `status` を引いて UI を再構築
- Project 一覧管理 (どの project があるか) は引き続き Swift 側 (= UserDefaults に保存)
- Master が down してたら spawn して再 attach

**消える責務**:
- `SSHTunnelManager.swift` の SSH spawn ロジック (master に移植)
- `ProjectStore.setupRemoteRPC` の RPC 接続ロジック (master が tunnel 持つので不要)
- `RemoteRPCRegistry` (これも master 側で持つ。Mac は client が要る時に master 経由で問い合わせ)
- `LauncherScriptGenerator.swift` 全部 (master が PTY 直接管理)
- bash launcher script 全廃

## Migration 戦略

big bang はリスク高い。**段階的に**:

### Phase 0: Design + IPC スキーマ確定 (現在)
- 本ドキュメント
- ユーザーレビュー

### Phase 1: master skeleton
- `belve-persist -mac-master -socket PATH` モード追加
- ping op だけ実装
- Belve.app から spawn + ping 通る所まで
- まだ既存パスは何も変えない

### Phase 2: setup orchestration を master に移譲
- `ensureSetup` op 実装 (deploy_bundle + ssh belve-setup を Go で再実装)
- ProjectStore.setupRemoteRPC が master.ensureSetup を呼ぶ
- bash launcher の deploy_bundle / belve-setup 呼び出し部分を削除
- 既存の SETUP_LOCK 一式も削除
- pane open は引き続き launcher 経由 (= ssh は呼ばないが belve-persist client は launcher が起動)

### Phase 3: tunnel 管理を master に移譲
- `SSHTunnelManager.swift` のロジックを master に移植
- Swift 側は IPC wrapper だけに

### Phase 4: session 管理を master に移譲
- `openSession` op 実装
- launcher 完全撤廃 (= Belve.app が直接 master.openSession して xterm に socket attach)
- per-pane local belve-persist daemon を master が吸収

### Phase 5: cleanup + 永続化
- 状態 dump/restore
- 古い code 削除
- ドキュメント更新

各 phase 終了時点でアプリは動く状態をキープする。

## Lifecycle

### Master の起動
- Belve.app 起動時に `/tmp/belve-master.sock` への ping を試行
- 応答なければ master spawn (`open -g` ではなく直接 fork → detach、Belve.app の child にしない)
- spawn 後 ping 成功するまで polling (max 5s)

### Master の死活監視
- IPC client は接続切れを検知したら master を再 spawn → 再 attach
- master 自身も自分の health 状態を持つ (panic recovery, log)

### Master の停止
- Belve.app からの明示的 `shutdown` op で停止
- 通常は止めない (Belve.app が落ちても master は生き続ける)
- macOS reboot で死ぬのは仕方ない

### 多重起動防止
- 起動時に socket を bind 試行 → 失敗 = 既に master あり → 既存 socket に attach

## エラー / 失敗 UX

「no silent fallback」原則を踏襲:

- `ensureSetup` 失敗 → Belve.app が project レベルでエラー表示 (sidebar にバッジ + tooltip)
- pane open 時 setup 未完 → "Setting up project..." 表示。ready になったら自動接続
- pane open 時 setup failed → "Setup failed [Retry]" を pane に表示
- master spawn 失敗 → app modal で表示 + Belve.app 機能制限モード

## 後方互換 / 既存コードの扱い

- 既存の `belve-setup` shell script は **VM 側にそのまま残す**。master は内部から `ssh host belve-setup ...` を呼ぶだけ。
- 既存の `belve-persist -router` / broker モードは変更なし。master は新モード追加。
- 既存の SSHTunnelManager 等は phase 2-3 で削除予定だが、その間は並走。

## 決定事項 (2026-04-23)

1. **Master の死活**: panic recovery しない。死んだら次の Belve.app 起動で spawn される。
   - 理由: master の中身は idempotent op だけ (state は VM/container 側に永続化済) なので、再起動コストが小さい
2. **Bundle version mismatch**: handshake で version 比較、不一致なら master を Belve.app から kill → 自動 spawn → 新版で attach
   - master は session を直接持たない時期 (phase 2-3) に decision なら sessions は VM 側 broker が persist してるので無問題
   - phase 4 以降で session を master が吸収した後は、master restart で session 切断 → reattach (= broker は VM 側で生存)
3. **Phase 2 と 4 を合体**: launcher を一度に撤廃する。中途半端な「ssh は呼ばないが TCP は残す bash」状態を避ける。
   - Phase 2-合体 = ensureSetup + openSession + tunnel まで master に集約、launcher 完全撤廃
4. **既存 session の救済 (= phase 4)**: 切断してユーザー reattach。
   - PTY broker は VM/container 側にいるので session 内容は失われない。Mac 側の attach 状態だけ作り直し。

## 進め方 (確定版)

| Phase | 内容 | 規模 | 完了条件 |
|---|---|---|---|
| 1 | master skeleton + ping op + Belve.app spawn/attach | 1-2h | `MasterClient.ping()` 通る |
| 2+3+4 | ensureSetup + tunnel + session を master に集約、launcher 完全撤廃 | 7-10h | 既存機能フルカバー、bash launcher なし |
| 5 | cleanup + dead code 削除 + ドキュメント | 1-2h | git diff で残骸ゼロ |

合計 9-14 時間。複数 session 想定。各 phase 終了でアプリは動く状態をキープ。
