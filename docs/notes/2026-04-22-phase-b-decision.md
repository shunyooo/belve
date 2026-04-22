# Phase B 設計決定: VM 中継 broker による SSH forward 1本化

作成日: 2026-04-22
ステータス: 設計決定済み、実装着手中

## 1. 問題

SSH `MaxSessions`（デフォルト 10）を超えて接続障害が発生する。

### 現状の session 消費

```
Mac → SSH ControlMaster (1 TCP) → VM sshd
├── SSH forward → container A:19222 (PTY broker)    = 1 session
├── SSH forward → container A:19224 (control RPC)   = 1 session
├── SSH forward → container B:19222                 = 1 session
├── SSH forward → container B:19224                 = 1 session
├── ssh host "belve-setup ..."                      = 1 session (一時的)
├── ssh host "ls ..."                               = 1 session (一時的)
└── ...
```

4 プロジェクトで forward 8本 + exec 散発で 10 session に到達。

### 現状の調査結果 (2026-04-22)

- VM 上に broker **なし** (127.0.0.1:19222 は listen していない)
- container 内に broker が **10個** 常駐 (docker exec -d で起動)
- Mac から各 container IP に直接 SSH forward (172.17.0.X:19222)
- VM 上の belve-persist プロセス 39個（大半は container 内プロセスの PID namespace 表示）

## 2. 検討した選択肢

### A. sshd の MaxSessions を上げる

- **実装**: `/etc/ssh/sshd_config` に `MaxSessions 100`
- **工数**: 5分
- **メリット**: 即効性、コード変更なし
- **デメリット**: 根本解決ではない。50プロジェクトで再発。他人の環境では使えない
- **判断**: 暫定対策としては有効だが、根本的に健全な状態ではない

### B. VM に中継 broker を1つ置く（doc の Phase B）

- **実装**: VM broker が Mac からの接続を受け、session 名で container を判定して転送
- **工数**: 3-5日
- **メリット**: SSH forward 1本。プロジェクト数に依存しない。VS Code と同じ方向性
- **デメリット**: VM broker に routing ロジックが必要。実装コスト大

### C. PTY と RPC を同じポートで多重化（Phase A）

- **実装**: 19222 と 19224 を 1 ポートに統合
- **工数**: 1-2日
- **メリット**: forward 半減 (project あたり 2→1)
- **デメリット**: まだ project 数に比例して session 消費。10 project で 10 session → MaxSessions ギリギリ
- **判断**: Phase B で構造が変わるので手戻り。単独ではやらない

### D. SSH forward をやめて SSH stdio で直結

- **実装**: `ssh host "docker exec -i container belve-ipc"` で stdin/stdout 通信
- **工数**: 2-3日
- **メリット**: forward ゼロ。container 内に常駐プロセス不要
- **デメリット**: セッション永続化ができない。SSH exec が切れたら通信も切れる
- **判断**: PTY 永続化が必須要件なので不採用

### E. VM broker が docker exec -it で直接 PTY 管理（案2）

- **実装**: VM broker が `docker exec -it container bash` で PTY を起動・管理
- **工数**: 2-3日
- **メリット**: container 内に常駐プロセス不要。最もシンプル
- **デメリット**: **docker exec 経由のプロセスは docker exec 接続が切れると kill される**（過去の実験で確認済み）。SIGHUP ではなく Docker daemon が強制終了するため、nohup/setsid では回避不可
- **判断**: 不採用。セッション永続化を保証できない

## 3. 決定: 案B（VM 中継 broker）

### 判断基準

1. **セッション永続化は必須** — container 内に常駐 broker が必要（案D, E は不可）
2. **SSH session 消費を project 数に依存させない** — 案A, C は将来的に再発
3. **VS Code と同じ方向性** — 1 VM = 1 server で全 project を捌く構造が正しい
4. **根本的に健全な状態** — ユーザーの明示的な要望

### 採用するアーキテクチャ

```
Mac → SSH forward 1本 → VM broker:19222
                              │
                    session 名で routing
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
      container A:19222  container B:19222  container C:19222
      (常駐 broker)     (常駐 broker)     (常駐 broker)
```

### SSH session 消費

| 項目 | 消費 |
|---|---|
| SSH ControlMaster | 1 |
| SSH forward (VM broker) | 1 |
| ssh exec (belve-setup 等) | 一時的 |
| **合計** | **2 + α、project 数に依存しない** |

### 変更点

1. **VM broker**: Mac からの TCP 接続を accept し、session 名から container IP を解決して転送
2. **belve-setup**: VM broker を起動（container broker は従来通り）
3. **LauncherScriptGenerator**: forward を VM broker 1本に変更
4. **SSHTunnelManager**: project ごとの forward → VM 単位に変更
5. **Mac 側 tcpbackend**: VM broker に接続（container IP 不要）
6. **control RPC**: VM broker 経由で多重化（container ごとの forward 不要）

### container 内 broker が必要な理由（再確認）

- docker exec 経由のプロセスは接続切断時に Docker daemon が kill する
- `docker exec -d`（detached）で起動すれば常駐可能
- container 内 broker は PTY セッション（シェルプロセス）を保持し、Mac 切断→再接続時に scrollback 含めて復元する
- この仕組みは tmux を置き換えた belve-persist の設計そのもの

## 4. container → VM 間のネットワーク

Docker のデフォルト bridge network で container 同士・VM ↔ container は TCP で直通。
SSH forward 不要。VM broker は `172.17.0.X:19222` に直接 TCP 接続できる。

container IP は `belve-setup` が `docker inspect` で取得し `~/.belve/projects/<PROJ>.env` に保存済み。
VM broker はこの env を読むか、`docker inspect` で動的に解決する。

## 5. control RPC の統合

現状: container ごとに 19224 で control listener → Mac から SSH forward で到達

Phase B 後: VM broker が control RPC も中継。Mac → VM broker:19222 の 1 接続で PTY + RPC 両方。

ただし、PTY (binary protocol) と RPC (NDJSON) は異なるプロトコル。統合方法:
- **案1**: VM broker の 19222 で受けて、最初のメッセージで PTY/RPC を判定
- **案2**: VM broker で 19222 (PTY) + 19224 (RPC) の 2 ポートを listen するが、forward は 1 本 (19222 だけ forward し、RPC は VM broker 内で処理)
- **案3**: PTY も RPC も NDJSON に統一

→ 案2が最もシンプル。RPC は VM broker が container に `docker exec` で中継するので forward 不要。

## 6. 関連する過去の実験・知見

- **PTY fd GC バグ** (2026-04-15): Go の `os.File` が GC で fd を閉じる問題 → `openPTY()` を `*os.File` 返しに修正済み
- **transport desync** (2026-04-15): `writeMsg` の 2回 Write が interleave → 1回の atomic Write に修正済み
- **docker exec プロセス kill** (2026-04-10): docker exec 切断時に子プロセスが強制終了 → container 内常駐 broker で対処
- **belve-persist binary 更新漏れ** (2026-04-15): container 内の古いバイナリが原因で desync → md5 チェック + 自動更新で対処

## 7. 実装の順序

1. VM broker に routing 機能を追加 (Go)
2. belve-setup で VM broker を起動
3. Mac 側の forward を VM 1本に変更 (Swift + shell)
4. control RPC を VM broker 経由に変更
5. テスト・動作確認
6. 旧 container 直接 forward のコードを削除
