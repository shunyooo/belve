# Broker アーキテクチャ再設計: 1 VM = 1 broker への移行

作成日: 2026-04-22
ステータス: 設計合意済み、実装未着手

## TL;DR

現状: project ごとに container 内 broker + Mac から 2 本ずつ port forward。多 project で SSH `MaxSessions` (デフォルト 10) を突破して全体が機能不全。

理想: VS Code Remote SSH と同じ「**1 VM = 1 broker (常駐) + 1 SSH forward (multiplexed)**」構造。container には常駐プロセス無し、必要時だけ `docker exec -i` で stdio forwarder を spawn。

実装工数: 3-5 日。Phase A (port forward 統合) → Phase B (per-container broker 廃止) の 2 段階。

---

## 1. 経緯

### 1.1 元の設計 (現状)

Belve はリモート開発環境として:
- Plain SSH project: VM 上に shell pane を spawn
- DevContainer project: container 内に shell pane を spawn

セッション永続化のため `belve-persist` という Go 製 broker を導入。tmux 不要で PTY を切断/再 attach 可能。

broker の配置:
- **Plain SSH**: VM 上で 1 broker (`tcplisten 127.0.0.1:19222`)
- **DevContainer**: 各 container 内で 1 broker (`tcplisten 0.0.0.0:19222`)

Mac 側は project ごとに `ssh -O forward -L LPORT:RHOST:19222 host` で broker に到達。

ファイル ops / git ops は当初 `executeSSH(host, "ls -la")` 形式で `ssh host cmd` を spawn してた。

### 1.2 RPC 化 (本日 2026-04-22 完了)

ファイル tree / git status の **5 秒 polling 由来のちらつき** を根治するため:
- broker に control RPC listener を追加 (NDJSON over TCP, port 19224)
- Mac 側 `RemoteRPCClient` で永続接続 → ls/stat/read/write/git ops を multiplex
- file watch (fsnotify) を push event 経由で配信、polling 廃止

実装は `feat(belve-persist): control RPC listener` 〜 `perf: replace 5s polling with fsevent push subscription` の 5 commits 参照。

### 1.3 露呈した問題

RPC を入れた瞬間、ターミナル入力ラグ + reload 遅延が発生。

調査して判明した経路:
1. control listener は **新 binary でしか動かない**
2. binary 配布は **belve-setup (= ターミナル起動時のみ)** 経由
3. → ユーザーが触ってない project の broker は古いまま (control listener 無し)
4. → Mac の RPC が当該 project に対して失敗
5. → provider が `executeSSH` fallback に落ちて `ssh host cmd` を spawn
6. → SSH `MaxSessions` (デフォルト 10) を突破 → `Session open refused by peer`
7. → ssh exec が hang して Mac 上に累積 (67 procs 確認)
8. → master 自体が応答しない → `ssh: connect timed out`

「文字入力ラグ」の正体: Mac → broker への TCP 経路自体は別だが、SSH master が refused のキューで詰まると port forward の応答もスローダウン (= PTY 入出力ラグ)。

### 1.4 SSH MaxSessions を超える理由

session スロット消費の内訳:
- SSH master 接続: 1 session
- 各 port forward: 1 session
- ssh exec (`ssh host cmd`): 1 session

現状、project ごとに 2 forward (PTY broker + control RPC):
- 12 projects × 2 = **24 sessions** (forward だけで sshd の上限を 2.4 倍超過)
- + ssh exec のバースト

これは構造的な問題。

---

## 2. 比較: VS Code Remote SSH の実装

VS Code は同類の問題を解決済み。アーキテクチャ:

1. **VM 1 個 = VS Code Server 1 個** (常駐 daemon)
2. **Mac から SSH forward は 1 本のみ** (server へ)
3. server 越しに **JSON-RPC over single channel で全 ops を multiplex** (file ops / git / terminal / extension host 全部)
4. **DevContainer は server (= VM 上) から `docker exec`** で操作。container 内に server を置かない
5. **User port forward も VS Code が自前 proxy** (Mac で listen → server channel に bytes 流す → SSH session 消費 0)

→ 何ワークスペース開いても SSH session 消費は ~3-5。

Belve も同方向に寄せれば構造的にスケールする。

---

## 3. 現状アーキテクチャ (詳細)

```
Mac (Belve.app)
├── Project "clay-app-report" (DevContainer)
│   ├── PTY pane × N → SSH forward → container ctr_A:19222
│   └── RPC client → SSH forward → container ctr_A:19224
├── Project "meal-tracker" (DevContainer)
│   ├── PTY pane × N → SSH forward → container ctr_B:19222
│   └── RPC client → SSH forward → container ctr_B:19224
├── Project "kawamoto-clay-dev-v2" (Plain SSH)
│   ├── PTY pane × N → SSH forward → VM:19222
│   └── RPC client → SSH forward → VM:19224
...

VM (kawamoto-clay-dev-v2.asia-northeast1-a...)
├── belve-persist (VM broker)
│   ├── PTY broker: 127.0.0.1:19222
│   └── Control RPC: 127.0.0.1:19224
├── container ctr_A (clay-app-report DevContainer)
│   └── belve-persist (container broker)
│       ├── PTY broker: 0.0.0.0:19222
│       └── Control RPC: 0.0.0.0:19224
├── container ctr_B (meal-tracker DevContainer)
│   └── belve-persist (container broker)
│       ├── PTY broker: 0.0.0.0:19222
│       └── Control RPC: 0.0.0.0:19224
└── ... (project ごとに container + broker × 1)
```

問題点:
- **broker proc が project 数だけ存在** (12 projects = 12 brokers)
- **port forward が 24 本** = SSH session 24 個消費
- binary update が container ごとに必要 (belve-setup でしか走らない)
- ログがバラける、運用面でも見通し悪い

---

## 4. 理想形

### 4.1 構造図

```
Mac (Belve.app)
└── 1 SSH master per VM (TCP 1 本) ← ControlMaster で multiplex
    └── 1 SSH forward → VM broker port 19222
                            │
        (NDJSON + channelId で multiplex)
        │
        ├── PTY channel (per pane)
        │     ├── Plain SSH project: VM 上で直接 shell spawn
        │     └── DevContainer: docker exec -it container shell
        │
        ├── Control RPC channel
        │     ├── VM-local ops: 直 syscall
        │     └── Container ops: docker exec -i belve-ipc (long-lived stdio)
        │
        ├── Push event channel (fsevent, status, etc.)
        │
        └── User port forward channels (multiplex 任意の TCP proxy)

VM (1 broker only)
└── belve-broker (フル機能)
    ├── Mac SSH forward を accept (port 19222)
    ├── 自分で fs ops 実行 (Plain SSH project 用)
    ├── container ごとに docker exec -i belve-ipc を long-lived で維持
    └── PTY 起動: docker exec -it (per pane)

Container (常駐プロセス無し)
└── belve-ipc (stdio forwarder, docker exec で lazy 起動)
    └── stdin/stdout で broker と NDJSON 会話、container 内で fs ops 実行
```

### 4.2 SSH session 消費

| 項目 | 消費 |
|---|---|
| SSH master | 1 / VM |
| Port forward | 1 / VM |
| ssh exec | 0 (basically) |
| **合計** | **2 / VM、project 数に依存しない** |

### 4.3 各 op の経路と性能

| 操作 | 経路 | レイテンシ |
|---|---|---|
| Container 内 file op | TCP → mux → stdio → fs syscall | ~1-5ms |
| VM 内 file op | TCP → mux → fs syscall | ~1-3ms |
| PTY 入出力 | TCP → mux → PTY | ~1-3ms |
| 初回 container 接続 | docker exec spawn | ~50-150ms (一度だけ) |
| File 変更検知 | container 内 inotify → push ch | ~10ms |
| User port forward | Mac listen → mux → broker proxy | TCP 直結とほぼ同等 |

### 4.4 デプロイ構成

| 配置 | 内容 | 配布方法 |
|---|---|---|
| Mac | Belve.app | アプリ単体 |
| VM | `belve-broker` | SCP (deploy_bundle 既存ロジック流用) |
| Container | `belve-ipc` (小さい forwarder) | VM が `docker cp` |

container 内に常駐 broker なし。`docker exec` で起動された短命プロセスが「container がアクティブな間だけ」存在。

### 4.5 障害復旧

| 障害 | 復旧 |
|---|---|
| Mac 再起動 | VM broker は生存、PTY scrollback も維持、再 attach で full state 復元 |
| SSH master 切断 | Mac が reconnect → forward 再確立 → broker 再 attach |
| Container 再起動 | docker exec EOF → 次の op で lazy 再 spawn |
| Container destroy | broker が container 不在を検出 → subchannel 破棄、UI に通知 |
| VM 再起動 | broker 死亡 → 再 deploy + 起動 (belve-setup) |
| Belve binary 更新 | 同 host の他 project に影響なし、新 broker は次回 deploy で起動 |

---

## 5. 副作用と対処

### 5.1 機能面

| 副作用 | 影響 | 対処 |
|---|---|---|
| Container 再起動で docker exec stdio が EOF | broker が当該 subchannel 切断検知 → reconnect | EOF 検出 → 自動再 spawn |
| Container 削除/再作成で CID 変化 | 旧 subchannel 死亡 | belve-setup の env 書き換えを broker が watch → 新 CID で再接続 |
| Container 停止中の op | docker exec 失敗 | エラー返却 → UI で「container offline」 |
| Mac broker proc 死亡時の cleanup | docker exec の子プロセスは orphan? | docker daemon が reap (現状と同じ挙動) |

### 5.2 性能面

| 項目 | 現状 | 新方式 | 差 |
|---|---|---|---|
| 初回 container op | TCP forward 確立 ~10ms | docker exec spawn ~100ms | +90ms (一度だけ) |
| Hot ops (ls/stat/read) | TCP → broker → fs | TCP → mux → stdio → fs | ほぼ同等 |
| Throughput | TCP stream | stdio stream over TCP | 同等 |
| VM 上の process 数 | container ごと 1 | container ごと 2 (exec wrapper + ipc) | 2x |

### 5.3 微妙ポイント

- **stderr drain**: docker exec の stderr 流しっぱなしだとバッファリング詰まる。`>/dev/null` か別 goroutine で読み捨て
- **権限**: docker exec はデフォルト root。container 内で作るファイルが root 所有 (現状と同じ)
- **PTY セッションは別経路**: shell pane は `docker exec -it container shell` を pane ごとに別途起動。ペイン数だけ exec proc 増える
- **fsnotify in container**: inotify は namespace 内で動く。docker exec 経由でも問題なし
- **マイグレーション中の session 喪失**: 旧 container broker 全 kill → 既存 PTY セッション一斉切断 → 1 回だけ痛い

### 5.4 やめた方がいい状況

- container が頻繁に re-create される運用 (subchannel reconnect 多発)
- docker daemon が遅い VM (exec ≥ 200ms)
- VM の docker socket にアクセス権限が制限されてる環境

→ 現状のユーザー (個人専用 GCE VM、container 長寿命) には致命的な問題は無い。

---

## 6. 段階的実装計画

### Phase A: Port forward 統合 (PTY + control を 1 forward に)

**目的**: project ごとの forward を 2 → 1 に半減。

**実装**:
1. broker protocol を multiplex 対応 (channel header + payload)
   - 現状は PTY 用 TCP listener と control RPC TCP listener が別ポート
   - 1 listener に統合、最初のメッセージで `{"channel":"pty","session":"..."}` or `{"channel":"control"}` を宣言
2. Mac 側 RemoteRPCClient を multiplex 対応
   - PTY 用 sub-client + control 用 sub-client が同じ TCP を共有
   - belve-persist (Mac side) も同じ TCP に乗る
3. SSHTunnelManager から control 用 forward 削除 (PTY forward に統合)

**効果**: 12 projects → 12 forwards = 12 sessions。MaxSessions=10 にはまだ届かない (たかが 2 削減)。

**工数**: 1-2 日。

### Phase B: Per-container broker 廃止 (1 VM = 1 broker)

**目的**: container ごとの broker をなくして、broker 数を VM 数まで減らす。

**実装**:
1. VM-side broker に **container subchannel manager** 追加
   - container ID ごとに `docker exec -i CID belve-ipc` を long-lived で維持
   - 必要に応じて lazy 起動、container EOF で再 spawn
2. **`belve-ipc` (container 内 stdio forwarder)** 新規実装
   - stdin/stdout で NDJSON
   - container 内で fs ops 実行
   - inotify watch 配信
3. broker protocol に「**target container**」フィールド追加
   - VM-local op: target なし → broker 自身が処理
   - Container op: target=CID → 該当 subchannel に dispatch
4. PTY も同方式で:
   - PTY pane 起動: broker が `docker exec -it CID shell` (or VM 上で直接 shell)
   - 入出力は broker 経由で multiplex
5. Mac 側 SSHTunnelManager から **container 別 forward を全削除**
   - VM 1 forward だけになる
6. PortForwardManager の user port forward を **broker 経由 proxy** に書き換え
   - Mac で TCP listen → broker channel に bytes 流す → broker が remote service にパス

**効果**: 12 projects on 1 VM → forward 1 本 → SSH session 2 個。

**工数**: 2-3 日。

### Phase C (任意): user port forward の自前 proxy 化

Phase B で済んでなければ。**SSH session 0 消費** で任意の port forward 提供可能。

**工数**: 0.5-1 日。

---

## 7. 依存・前提

### 7.1 belve-broker / belve-ipc の binary 配布

- `belve-broker`: VM 上に SCP (現状の deploy_bundle ロジック流用)
- `belve-ipc`: VM 上に置いておき、container ごとに `docker cp` (lazy 配布)
- container には事前に何も入れない (belve-setup で `docker cp` のみ)

### 7.2 既存 project の移行

- ユーザーが project select した瞬間: 旧 container broker を kill → 新 VM broker に切替
- 1 度だけ既存 PTY セッションが切断される
- 切断後は belve-persist (Mac side) の reconnect ロジックで自動再 attach
- scrollback は belve-broker 側の replay buffer にあれば復元

### 7.3 multi-VM 対応

- VM ごとに独立した broker
- Mac の RemoteRPCRegistry は VM 単位 (現在は project 単位)
- channel 内に target container の field があれば 1 broker で複数 container 捌ける

---

## 8. 未解決の検討事項

1. **broker protocol 詳細**:
   - Channel header 形式 (binary vs JSON)
   - 1 channel あたりの flow control
   - 大きな payload (file read で MB 級) のチャンク送信

2. **container subchannel の lifecycle**:
   - 何分アイドルで close するか
   - 再 spawn のレート制限

3. **既存 belve-persist の責務分割**:
   - 現状: PTY broker + control RPC が同 binary
   - 新: VM broker + container ipc に分割
   - コード共有方法 (Go module 構造)

4. **マイグレーション期間中の互換性**:
   - 新 broker がデプロイされてない VM に新 Mac クライアントが繋いだ時の挙動
   - フォールバック持たせるか、エラー出して redeploy 促すか

5. **Plain SSH project の扱い**:
   - 当面は VM 上で直接 shell spawn (`docker exec` 不要)
   - Container subchannel 機構と同じ抽象に乗せられるか

6. **テスト戦略**:
   - VM broker の単体テスト
   - container subchannel の mock
   - 切断 / 再接続シナリオ

---

## 9. 参考: 直前までの実装状況 (2026-04-22 時点)

完了済み:
- `feat(belve-persist): control RPC listener for filesystem / git ops`
- `feat(rpc): Mac client + provider migration to control RPC`
- `feat(belve-persist): fsnotify-based watch + push events`
- `perf: replace 5s git/file-tree polling with fsevent push subscription`
- 各 provider の `readFile` / `writeFile` / `modificationDate` / `gitDiffHunks` / `gitCheckIgnore` / 他 RPC 化
- ファイル open 時の watch 化 (modificationDate polling 廃止)

未完了 (本ドキュメントのスコープ):
- Phase A: port forward 統合
- Phase B: per-container broker 廃止 (1 VM = 1 broker)
- Phase C: user port forward の自前 proxy 化

---

## 10. 関連ファイル / 過去ドキュメント

- `tools/belve-persist/main.go`: 現 broker (PTY + tcpbackend mode)
- `tools/belve-persist/control.go`: control RPC (本日追加)
- `Sources/Belve/Services/SSHTunnelManager.swift`: SSH master + forward 管理
- `Sources/Belve/Services/RemoteRPCClient.swift`: Mac side RPC client
- `Sources/Belve/Services/WorkspaceProvider.swift`: provider 抽象 + 各実装
- `Sources/Belve/Resources/bin/belve-setup`: VM/container での broker 起動
- `Sources/Belve/Terminal/LauncherScriptGenerator.swift`: PTY launcher (forward 確立含む)
- `.claude/projects/-Users-s07309-src-dock-code/memory/project_tcp_persist.md`: TCP persist 移行時の設計メモ
- `.claude/projects/-Users-s07309-src-dock-code/memory/project_broker_kill.md`: broker kill 挙動メモ
- 過去プラン: `.claude/plans/shimmering-hugging-panda.md` (SSH tunnel 移行プラン、本ドキュメントの前段)
