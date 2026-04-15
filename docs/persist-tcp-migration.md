# DevContainer 接続: docker exec → TCP 移行

## 背景

DevContainer 接続で docker exec をデータパス（ターミナル I/O の経路）に使用していたが、コンテナ内の子プロセス（bash）が定期的に SIGKILL（exit 137）され、docker exec チェーン全体が連鎖崩壊してターミナルが disconnected になる問題が繰り返し発生していた。

### 旧アーキテクチャ（不安定）

```
xterm.js → SSH → host persist(PTY) → docker exec -it(PTY) → container client → Unix socket → container daemon(PTY) → bash
```

- PTY が 4 層
- docker exec がデータパスの中核
- docker exec の子プロセスが SIGKILL されると全チェーンが崩壊

### 新アーキテクチャ（TCP、2026-04-14 移行）

```
xterm.js → SSH → host persist → TCP:19222 → container broker(PTY) → bash
```

- PTY は 2 層（SSH + container broker）
- docker exec は初回ブローカー起動のみ（データパスに入らない）
- ブローカーが自動 respawn（子プロセス SIGKILL 時にシェル再起動）

## TCP ブローカー設計

### コンテナ側: `-tcplisten`

1 コンテナ 1 プロセス。ポート 19222 で TCP リッスン。複数セッション（ペイン）をセッション名で多重化。

```bash
belve-persist -tcplisten 0.0.0.0:19222 -command /root/.belve/session-bootstrap.sh
```

- TCP 接続受付 → `msgSession` ハンドシェイク（セッション名 + 初期サイズ）
- セッション未存在 → PTY + 子プロセス生成
- セッション存在 → replay buffer 送信 + クライアント登録
- 子プロセス SIGKILL 時 → 自動再起動（最大 10 回）

### ホスト側: `-tcpbackend`

ホスト persist daemon が TCP でコンテナブローカーに直接接続。子プロセス不要。

```bash
belve-persist -socket HOST_SOCK -tcpbackend 172.17.0.2:19222 -session belve-28CA2F90-3
```

- TCP 接続 → `msgSession` 送信 → replay buffer 受信
- Unix socket クライアント ↔ TCP 双方向ブリッジ
- TCP 切断時 → 自動再接続（最大 100 回）

### ワイヤプロトコル

```
[type:1byte][length:4bytes big-endian][payload:N bytes]

msgData    = 0  # PTY データ
msgResize  = 1  # [cols:2][rows:2]
msgSession = 2  # session_name + \0 + [cols:2][rows:2]
```

### コンテナ IP 管理

`belve-setup` で `docker inspect` → CIP を `.env` に保存。各コンテナが独自 IP を持つのでポート競合なし。

```bash
# ~/.belve/projects/28CA2F90.env
CID=47d24f73df85...
RWS=/workspaces/clay-api-flamel
CIP=172.17.0.2
```

### リサイズの流れ

```
xterm.js fitAddon → PTYService.setSize → SSH SIGWINCH
→ belve-persist attach SIGWINCH → msgResize over Unix socket
→ host daemon → msgResize over TCP → broker → setPtySize + SIGWINCH
```

docker exec stty ハックは完全不要。

## 未解決の問題

### Claude Code self-SIGKILL

strace で確認済み: Claude Code（Node.js）が `kill(self_pid, SIGKILL)` を実行して自殺している。原因不明。

- 常に Claude Code 実行中のペインだけが影響
- リサイズ（SIGWINCH 連打）時に発生しやすい
- OOM/cgroup/Docker restart は全て否定済み
- 対策: リサイズ debounce を 500ms に延長、ブローカー auto-respawn

### transport desync

TCP backend で `message too large` エラーが発生し入力不能になることがある。プロトコルのフレーミングがずれる問題。

## PTY の制約

Go 1.26 の `Setctty` は `TIOCSCTTY` に `arg=1` をハードコードしており、non-privileged コンテナ（CAP_SYS_ADMIN なし）では EPERM になる。現在は `Setctty: false` で運用。`bash: cannot set terminal process group` メッセージは cosmetic。

## デバッグツール

- `tools/belve-persist/remote-debug.sh` — ビルド・デプロイ・トレースの統合スクリプト
- `tools/belve-persist/trace-broker.sh` — strace でブローカーを起動
- `tools/belve-persist/watch-pane.sh` — ペインの PID を監視

## 関連ファイル

- `tools/belve-persist/main.go` — TCP ブローカー + TCP バックエンド
- `Sources/Belve/Resources/bin/belve-connect` — DevContainer 接続フロー
- `Sources/Belve/Resources/bin/belve-setup` — CIP 保存
- `Sources/Belve/Resources/bin/claude` — hooks 二重化防止
