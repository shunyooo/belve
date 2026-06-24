# yamux による SSH channel 多重化 (Phase 6)

**作成日**: 2026-06-24
**ステータス**: ✅ 実装完了 (Phase 1-4 + 後片付け、Phase 5 のみ未着手)
**関連**:
- [2026-04-22 broker-architecture-redesign](2026-04-22-broker-architecture-redesign.md) (Phase B — forward 1本化)
- [2026-04-23 mac-master-design](2026-04-23-mac-master-design.md)

---

## 実装後サマリ (2026-06-24 当日)

着手当日に Phase 1-4 + 後片付けまで一気に通した。結果と「計画と違ったこと」を以下に記録する (計画パートはそのまま参照用に残す)。

### 完了した commit (`main` 取り込み済み)

```
b53b939d3f8 fix(tunnel): schema-version the tunnel state file to discard stale entries
e78fdf5c964 refactor(persist): drop legacy TCP router/backend code paths
3b5f191f66f feat(master): auto-restart mac-master on binary mismatch
bb315edfabb refactor(mux): drop feature flag, always use yamux multiplexing
6a25cbd17e1 wip(mux): yamux channel multiplexing with feature flag (rollback point)
```

ロールバック: `git revert <hash>` で個別、または `git reset --hard c8cc19902da` (本作業前) で全戻し。

### 計画と違ったこと

**1. Feature flag (§3.6) を撤去した**

当初は `AppConfig.mux.{enabled, hosts}` + `BELVE_USE_MUX` env var で段階ロールアウトする計画だった。しかし実装途中で:

- flag があると「いざとなれば旧 path に戻せる」という空気が残り、結局「優しい fallback」と地続きになる
- 旧 path コードがメンテ対象として残り続ける
- flag 切替の検証コストが二経路ぶん発生

の議論があり、**flag を撤去して mux 一本に絞った** (`bb315edfabb`)。ロールバックはコード内 flag ではなく git commit ベースで対応する方針に変更し、`CLAUDE.md` の設計原則に明文化した。

**2. mac-master の自動再起動を入れた**

これは計画外。実装中、Go バイナリを rebuild しても「既存 master sock が生きてれば attach」するため、開発ループで毎回 `pkill -f mac-master` が必要なことが判明。既存の binary identity check (mtime + size) が **warning だけで attach** していたのを、**mismatch なら kill → respawn** に変えた (`3b5f191f66f`)。

2026-04-27 事故 (= master kill で全 pane 固まる) の懸念は、Phase 6 で per-pane daemon に reconnect loop が入ったため緩和される。

**3. tunnel state file の schema versioning**

これも計画外、運用バグの後追い対応。旧 master が書いた `/tmp/belve-master-state.json` の `routerForwards` (host → local port マップ) を新 master がそのまま再利用してしまい、**Mac local 19222 → VM 19200 (旧 router)** だった forward を「19201 行き」と誤認して broker port (= yamux 喋らない) に yamux session を張りに行き即切断ループになる事故が出た。

state schema に `Version: 2` を入れて、不一致なら state ファイルを discard する形に修正した (`b53b939d3f8`)。今後 remotePort や持ち物が変わる時は `persistedTunnelStateVersion` を bump する運用。

### 検証で確認できたこと

- yamux session up が `closed` でフラップせず維持される (broker port 誤接続の事故修正後)
- mac-master の TCP 接続: 1 host あたり **1 本** (`localhost:LPORT -> localhost:19223 ESTABLISHED`) で全 pane が多重化される
- VM 側 `-mux-router :19201` プロセスのみが残り、旧 `-router :19200` は完全消失
- per-pane daemon の reconnect loop が動作し、master 再起動を跨いで pane が回復する
- Belve.app rebuild → 再起動だけで mac-master と VM router 双方の新バイナリが自動展開される

### Phase 5 (未着手) で見るべき項目

- 実負荷 (42 pane) で SSH MaxSessions 起因の切断が再発しないかの本検証
- yamux config (`MaxStreamWindowSize=16MB`, `KeepAliveInterval=30s`, `AcceptBacklog=256`) のチューニング
- mux session 状態の UI 表示 (現状は log を見ないと分からない)
- VM 側 `sshd_config.d/belve-maxsessions.conf` (= `MaxSessions 100`) の撤回判定 (= mux 化後はデフォルト値で十分なはず)
- pane daemon log の "tcp disconnected" 表現が中身 Unix socket なのと噛み合っていないのを修正

---

## 0. 経緯と次アクション

### 0.1 経緯

2026-06-24 に「ターミナル接続が頻繁に切れる」という報告。調査結果:

- VM 側 broker の self-health check が CPU 高負荷で偽陰性 → exit ループ → session 全死、の問題は別途 commit `c8cc19902da` で self-health 削除済み (broker は accept error でしか死なない)
- 残る切断要因: **SSH MaxSessions 超過**
  - VM `sshd_config`: `MaxSessions 10` (default)
  - 実際の Mac → VM SSH channel 数: **27** (lsof 計測)
  - pane (= belve-persist client process) ごとに `127.0.0.1:19222` → SSH forward に **直接 TCP 接続** していて、1 接続 = 1 SSH channel を消費
- 短期対処として VM の `sshd_config.d/belve-maxsessions.conf` で `MaxSessions 100` に引き上げ (適用済み)
- 根本対策として本ドキュメントの yamux 多重化を計画

### 0.2 「以前 1 本化したはず」の誤解

過去の Phase B (`dfb61a50deb`「single SSH forward per VM via router」, 2026-04-22) は **port forward の 1 本化** をやっただけで、**SSH channel の多重化はされていない**:

- forward 1本化: ✓ (`19222 → 19200`, Mac 側 port は VM ごとに 1 個)
- channel 1本化: ✗ (pane ごとに別 TCP = 別 channel)

両者を混同していた。本 Phase 6 で channel 1本化を実装する。

### 0.3 次アクション (= 本実装の着手判断)

MaxSessions 100 で症状が消えたか **2-3 日経過観察** してから着手判断:

| 観察結果 | 対応 |
|---|---|
| 切断再発しない | yamux 実装は不要。本 doc は寝かせる |
| 再発するが別原因 (kernel limit / OOM / network) | そちらを潰す |
| 再発して channel 枯渇が確定 | Phase 0.2 から着手 |

判定材料:
- `ssh kawamoto-clay-dev-v2.asia-northeast1-a.aitech-kiwami-cole-dev 'sudo grep -i "open failed\|max sessions" /var/log/auth.log | tail -20'`
- Mac 側 `lsof -p $(pgrep -f 'ssh.*ControlMaster') -nP | grep -c TCP` の peak 観察

---

## 1. 現状アーキテクチャ詳細

### 1.1 belve-persist の mode 一覧

| mode | フラグ | 主処理 | プロセス常駐先 |
|---|---|---|---|
| `mac-master` | `-mac-master /tmp/belve-master.sock` | Mac 上で SSH ControlMaster / port-forward / setup orchestration | Mac (Belve.app から spawn、生存延長) |
| `router` | `-router 0.0.0.0:19200` | VM 上で listen、preamble JSON を読んで container broker に proxy | VM |
| `tcplisten` (broker) | `-tcplisten 0.0.0.0:19222 -command session-bootstrap.sh` | container 内で listen、session ごとに PTY を spawn、replay buffer 保持 | container |
| `controllisten` | `-controllisten 0.0.0.0:19224` | broker と同居、NDJSON 制御 RPC (ls/git/lsp/fsnotify) | container |
| `tcpbackend` (host bridge) | `-socket ... -tcpbackend 127.0.0.1:PORT -session NAME -route PROJSHORT` | **per-pane の detached daemon**。Unix socket を listen + TCP backend に張って双方向 bridge。**ここが 1 channel/pane を消費する張本人** | Mac (per pane、Setsid+Release で detach) |
| client (attach) | `-socket ...` | 既存 daemon に Unix socket attach | Mac (Belve.app の子) |

### 1.2 現在の per-pane データフロー (PTY)

```
[xterm.js WKWebView]
  ↕
[XTermTerminalView.Coordinator (Swift)]
  ↕ PTYService raw mode PTY
[belve-persist client (Unix socket attach)]
  ↕ Unix socket /tmp/belve-shell/sessions/belve-<projShort>-<paneIdShort>.sock
[belve-persist -tcpbackend daemon (per pane, Setsid detach)]
  preamble {"projShort":"XXXX","kind":"pty"}\n + msgSession + msgData...
  ↕ 127.0.0.1:LPORT  ─── ssh -L LPORT:127.0.0.1:19200 ──→  VM router :19200
                                                              ↓ dispatch
                                                            container broker :19222
                                                              ↓
                                                            session-bootstrap.sh → bash → claude
```

**SSH channel 数**: pane の数だけ消費 (= 50 pane → 50 channel)

### 1.3 既存 preamble protocol

`router.go`:

```go
type routePreamble struct {
    ProjShort string `json:"projShort"`
    Kind      string `json:"kind"` // "pty" | "control" | "health"
}
```

- 1 行 NDJSON、`\n` で終端
- 5 秒 read deadline
- preamble 後は upstream protocol (PTY なら `msgSession` から、control なら NDJSON RPC)
- `bufio.Reader` で残りバッファを upstream に flush してから `io.Copy` で双方向 piping

### 1.4 Pane spawn 経路

`Sources/Belve/Terminal/XTermTerminalView.swift` の `Coordinator.startPTY` remote パス (line ~466-554):

```swift
let port = try await SSHTunnelManager.shared.ensureRouterForward(host: host)
let args = [
    "-socket", sockPath,
    "-cols", String(cols), "-rows", String(rows),
    "-tcpbackend", "127.0.0.1:\(port)",
    "-session", sessionName,
    "-route", projShort,
]
// PTYService.spawn(belveBin, args, ...)
```

これが per-pane で per-channel な TCP を作る起点。

---

## 2. 設計方針

### 2.1 yamux を入れる層

```
[xterm.js × 50]
  ↕
[XTermTerminalView × 50]
  ↕ PTY
[belve-persist client × 50] (引数: -mux-via <unix-sock>)
  ↕ Unix socket × 50 → /tmp/belve-mux-listener-<host>.sock
[mac-master の muxManager (新規)]
  ・各 Unix socket conn を 1 yamux stream に変換
  ・host ごとに 1 個の yamux client Session を維持
  ↕ TCP 127.0.0.1:LPORT ── SSH -L LPORT:127.0.0.1:19201 ──→ VM router :19201
                                                              ↓ yamux Server
                                                              ↓ AcceptStream
                                                              ↓ preamble dispatch
                                                            container broker :19222
```

**SSH channel 数**: VM ごとに 1 個 (= 何 pane あっても 1 channel)

### 2.2 新旧 path の併存方針

CLAUDE.md の「優しい fallback は入れない」を厳守:

- **port 分けで完全分離**: 旧 path は VM 側 router の 19200 を使い続ける。新 path は **19201 (新 port)** を使う
- **Feature flag で明示切替**: `BELVE_USE_MUX` env var + `AppConfig.mux.enabled` / `mux.hosts` で host 単位 opt-in
- **silent fallback 禁止**: 新 path で dial refused になっても旧 path に自動で戻さない。明示的にエラー表示して、ユーザーが flag OFF に戻すまで動かない
- **ロールバック**: flag を false に戻すだけ。新 path のコードが入っていても OFF にすれば一切実行されない

### 2.3 ライブラリ選定

採用: **`github.com/libp2p/go-yamux/v5`** (最新 v5.1.0, 2025-07-29 release)

- libp2p / IPFS / Filecoin の本番運用で揉まれてる活発な fork
- HashiCorp 版 (`hashicorp/yamux`) と API はほぼ同じ
- HashiCorp 版より maintenance が active

代替検討:
- `hashicorp/yamux` — 安定だが release cadence 遅 (v0.1.2, 2024-09)
- `xtaci/smux` — 軽量、KCP 系で実績。本件では go-yamux で十分
- `inconshreveable/muxado` — archive 済み (採用 NG)

### 2.4 frame protocol

各 yamux stream の最初に既存 router 互換の NDJSON preamble を流す:

```
{"projShort":"abc12345","kind":"pty-mux","sessionName":"belve-abc12345-de56fa78","cols":120,"rows":40,"ver":2,"replay":"full"}\n
< 通常の PTY protocol: msgSession + msgData + msgResize ... >
```

設計上の決定:
- `kind` を `"pty-mux"` / `"control-mux"` にする (旧 path の `"pty"` / `"control"` と異なる値 → 誤って旧 port に届いたら router が unknown kind で reject)
- `ver: 2` フィールドで将来の breaking 用に予約
- `replay` field を新設: `"full"` (default、replay buffer 全送信) / `"skip"` (旧 `msgNoReplay` 相当) / `"tail"` (= 直近 N KiB だけ、optional)
- stream lifecycle は yamux 任せ (OPEN/DATA/CLOSE は内蔵)

---

## 3. 設計詳細

### 3.1 Mac 側 mac-master の改修

#### 新規 component: `muxManager`

```go
type muxManager struct {
    mu               sync.Mutex
    sessions         map[string]*yamux.Session       // host → session
    sessionsSpawning map[string]chan struct{}        // dedupe concurrent spawn
    tunnel           *tunnelManager                  // forward 確立
}

func (mm *muxManager) ensureSession(host string) (*yamux.Session, error) {
    // 1. 既存 session が ! sess.IsClosed() なら返す
    // 2. spawning lock 取って duplicate spawn 防止
    // 3. tunnel.ensureRouterForward(host, 19201) で local port 取得
    // 4. net.Dial("tcp", "127.0.0.1:LPORT")
    // 5. yamux.Client(conn, muxYamuxConfig())
    // 6. <-sess.CloseChan() を監視する goroutine 起動 (= lazy cleanup)
}

func muxYamuxConfig() *yamux.Config {
    cfg := yamux.DefaultConfig()
    cfg.MaxStreamWindowSize = 16 << 20             // 16 MiB
    cfg.KeepAliveInterval = 30 * time.Second
    cfg.ConnectionWriteTimeout = 10 * time.Second
    cfg.AcceptBacklog = 256
    return cfg
}
```

#### 新規 listener: Unix socket per host

```go
// /tmp/belve-mux-listener-<host-slug>.sock
// host-slug = host を sha1 で短縮 (= path 長制限回避)
func (mm *muxManager) startListener(host string) {
    sock := muxListenerPath(host)
    os.Remove(sock)
    listener, _ := net.Listen("unix", sock)
    for {
        conn, _ := listener.Accept()
        go mm.handleClient(conn, host)
    }
}

func (mm *muxManager) handleClient(client net.Conn, host string) {
    defer client.Close()
    sess, err := mm.ensureSession(host)
    if err != nil {
        // 明示的エラー: silent fallback しない
        client.Write([]byte("\x1b[31m[belve] mux session unavailable\x1b[0m\r\n"))
        return
    }
    stream, err := sess.OpenStream()
    if err != nil { return }
    defer stream.Close()
    // bidir copy: client ↔ stream
    go io.Copy(stream, client)
    io.Copy(client, stream)
}
```

#### Belve.app からの起動指示

mac-master は **常に listener を起動** (誰も繋がなければ no-op)。host への forward 確立は `tunnelManager.ensureRouterForward` の既存ロジック (Belve.app の `setupRemoteRPC` 経由) で済む。

### 3.2 VM 側 router の改修

新 mode: **`runMuxRouter(addr string)`**

```go
func runMuxRouter(addr string) {
    listener, _ := net.Listen("tcp", addr)
    for {
        conn, _ := listener.Accept()
        if tc, ok := conn.(*net.TCPConn); ok {
            tc.SetNoDelay(true)
            tc.SetKeepAlive(true)
        }
        go func(c net.Conn) {
            sess, err := yamux.Server(c, muxYamuxConfig())
            if err != nil { c.Close(); return }
            for {
                stream, err := sess.AcceptStream()
                if err != nil { return }
                go handleMuxStream(stream)
            }
        }(conn)
    }
}

func handleMuxStream(s *yamux.Stream) {
    defer s.Close()
    // 既存 handleRouterConn の preamble parser + resolveTarget + dialWithHealing を流用
    // ...
}
```

#### main.go の起動分岐

```go
muxListen := flag.String("mux-router", "", "TCP listen for yamux router (e.g. 0.0.0.0:19201)")
// ...
if *muxListen != "" {
    go runMuxRouter(*muxListen)
}
```

両 port 同時 listen 可能 (旧 `-router 0.0.0.0:19200` と共存)。

#### `belve-setup` script の更新

router 起動コマンドに `-mux-router 0.0.0.0:19201` を追加。古い router が動いてる VM では 19201 listen は無いので、Mac から dial すると refused → 明示的エラー表示 (silent fallback しない)。

### 3.3 belve-persist client の `-mux-via` mode

新 flag `-mux-via PATH` を追加 (既存 `-tcpbackend` と排他)。

```
belve-persist (client/daemon mode, mux):
  -socket   /tmp/belve-shell/sessions/belve-<projShort>-<paneIdShort>.sock
  -mux-via  /tmp/belve-mux-listener-<host-slug>.sock
  -session  belve-<projShort>-<paneIdShort>
  -route    <projShort>
  -cols     <N>
  -rows     <N>
```

実装方針: 既存の `runMasterTCPBackend` をリファクタして共通化、`runMasterMuxBackend` を新設:

```go
func runMasterBackend(opts backendOpts) {
    // opts.dialFn: () -> (net.Conn, error)  ← TCP or Unix
    // ... 共通の reconnect loop / preamble write / handshake / piping
}

func runMasterTCPBackend(...) {
    runMasterBackend(backendOpts{ dialFn: dialTCP, ... })
}

func runMasterMuxBackend(...) {
    runMasterBackend(backendOpts{ dialFn: dialUnix, ... })
}
```

#### XTermTerminalView 側の分岐

```swift
let args: [String]
if AppConfig.shared.muxEnabled(forHost: host) {
    let muxSock = "/tmp/belve-mux-listener-\(muxHostSlug(host)).sock"
    args = [
        "-socket", sockPath,
        "-cols", String(cols), "-rows", String(rows),
        "-mux-via", muxSock,
        "-session", sessionName,
        "-route", projShort,
    ]
} else {
    // 旧 path
    let port = try await SSHTunnelManager.shared.ensureRouterForward(host: host)
    args = [
        "-socket", sockPath,
        "-cols", String(cols), "-rows", String(rows),
        "-tcpbackend", "127.0.0.1:\(port)",
        "-session", sessionName,
        "-route", projShort,
    ]
}
```

### 3.4 Reconnect / lifecycle

#### Yamux session の死亡検知

```go
go func(host string, sess *yamux.Session) {
    <-sess.CloseChan()
    mm.mu.Lock()
    if mm.sessions[host] == sess {
        delete(mm.sessions, host)
    }
    mm.mu.Unlock()
    // 次回 ensureSession で lazy に再構築 (thundering herd 回避)
}(host, sess)
```

SSH forward 自体は `tunnelManager.healthCheckLoop` (15s) が死活監視・再確立する。yamux の上は 127.0.0.1:LPORT 経由なので forward が復活すれば即 dial 可能。

#### Pane client の reconnect

Mac mac-master の Unix socket listener が EOF を返す = pane client から見ると Unix socket 切断。pane client (= `runMasterMuxBackend`) は既存 `runMasterTCPBackend` と同じ reconnect loop で再 dial → muxManager が新 yamux stream を open → preamble 投げ直し。

#### Replay buffer resume

`msgNoReplay` の運用を preamble JSON 経由に統一:

```json
{"projShort":"...", "kind":"pty-mux", "sessionName":"...", "replay":"skip", ...}
```

- `"full"`: 全 replay buffer 送信 (= 通常の新規接続)
- `"skip"`: replay スキップ (= xterm.js が serialize state を持ってる時)
- `"tail"`: 直近 N KiB だけ (= 将来の最適化、optional)

broker 側 session 名 (`belve-<projShort>-<paneIdShort>`) は変えない。`getOrCreateSession` が **同名なら既存 session に追加 client として add** する既存挙動を再利用。

### 3.5 Flow control 設定

yamux default:
- `InitialStreamWindowSize` = `MaxStreamWindowSize` = 256 KiB

Belve のユースケース (claude TUI + MCP の重い burst, replay buffer 4 MiB):
- `MaxStreamWindowSize: 16 << 20` (16 MiB)
- `KeepAliveInterval: 30 * time.Second`
- `ConnectionWriteTimeout: 10 * time.Second`
- `AcceptBacklog: 256`

メモリーコスト:
- 50 stream × 16 MiB = 800 MiB が **上限値**
- 実メモリは「未読 + 飛んでる ACK」のみ。idle なら ~MB 単位
- Phase 5 で実測して必要なら tune (32 MiB 化 or 8 MiB に削減)

### 3.6 Feature flag

`AppConfig` に追加:

```swift
struct MuxConfig: Codable {
    var enabled: Bool = false       // 全 host 一律
    var hosts: [String] = []        // 個別 opt-in (enabled=false 時のみ評価)
}

extension AppConfig {
    func muxEnabled(forHost host: String) -> Bool {
        if ProcessInfo.processInfo.environment["BELVE_USE_MUX"] == "1" { return true }
        if ProcessInfo.processInfo.environment["BELVE_USE_MUX"] == "0" { return false }
        if mux.enabled { return true }
        return mux.hosts.contains(host)
    }
}
```

ロールアウト:
1. `mux.enabled = false, mux.hosts = []` (= default) でリリース
2. `mux.hosts = ["<test-vm-host>"]` でテスト host だけ新 path
3. 問題なければ `mux.hosts` に hosts 追加
4. 全 host 安定したら `mux.enabled = true` に切替
5. 1-2 ヶ月運用後、旧 path コード撤去 (Phase 6)

---

## 4. フェーズ別実装 task

### Phase 0: 着手準備 (~1 日)

| # | task | 変更ファイル | 行数目安 | リスク |
|---|---|---|---|---|
| 0.1 | 本 doc を確定 (= 草案 → 確定版に昇格) | docs/notes/2026-06-24-yamux-multiplex.md | 既存 | 低 |
| 0.2 | `tools/belve-persist/go.mod` に `github.com/libp2p/go-yamux/v5` 追加 + `go mod tidy` | go.mod, go.sum | ~10 | 低 |
| 0.3 | `AppConfig` に `MuxConfig` 追加 (load/save 含む) | Sources/Belve/Services/AppConfig.swift | +40 | 低 |

### Phase 1: VM router の 19201 受け入れ (~1 日)

| # | task | 変更ファイル | 行数目安 | リスク |
|---|---|---|---|---|
| 1.1 | `runMuxRouter()` 実装 | tools/belve-persist/router.go | +90 | 中 |
| 1.2 | main.go に `-mux-router` フラグ + 起動分岐 | tools/belve-persist/main.go | +15 | 低 |
| 1.3 | `belve-setup` の router 起動コマンドに `-mux-router 0.0.0.0:19201` 追加 | Sources/Belve/Resources/bin/belve-setup, router.go | +5 | 中 |
| 1.4 | trace mode `BELVE_MUX_TRACE=1` (VM 側) | tools/belve-persist/router.go | +30 | 低 |

**完了基準**: VM 上で `belve-persist -mux-router 0.0.0.0:19201` 起動 → Mac から `ssh -L 19201:127.0.0.1:19201 host` → 手書きの yamux client で stream open + preamble → broker 到達

### Phase 2: Mac muxManager + Unix listener (~1 日)

| # | task | 変更ファイル | 行数目安 | リスク |
|---|---|---|---|---|
| 2.1 | `tools/belve-persist/mux.go` 新規: muxManager, ensureSession, listener | tools/belve-persist/mux.go (新規) | ~200 | 高 |
| 2.2 | master.go で muxManager 初期化 + per-host listener 起動 | tools/belve-persist/master.go | +30 | 中 |
| 2.3 | `tunnel.ensureRouterForward(host, 19201)` への引数追加 | tools/belve-persist/tunnel.go, mux.go | +10 | 低 |
| 2.4 | trace mode `/tmp/belve-mux-mac.log` | tools/belve-persist/mux.go | +20 | 低 |

**完了基準**: mac-master 起動 → `/tmp/belve-mux-listener-*.sock` が見える → `socat - UNIX:...` で接続 + preamble → broker 到達

### Phase 3: pane client の `-mux-via` mode (~0.5 日)

| # | task | 変更ファイル | 行数目安 | リスク |
|---|---|---|---|---|
| 3.1 | main.go に `-mux-via` + `runMasterMuxBackend` (TCPBackend をリファクタ + 共通化) | tools/belve-persist/main.go | +50 | 中 |
| 3.2 | reconnect loop の Unix socket 対応 | main.go | 上に含む | 中 |
| 3.3 | XTermTerminalView で `muxEnabled(forHost:)` 分岐 | Sources/Belve/Terminal/XTermTerminalView.swift | +25 | 中 |

**完了基準**: mux 有効 host で pane 1 個 → claude 動作。 mux 無効 host → 旧 path で動作。lsof で SSH channel 数が `pane 数` → `1` に減ってることを確認。

### Phase 4: Control RPC の mux 化 (~1 日)

| # | task | 変更ファイル | 行数目安 | リスク |
|---|---|---|---|---|
| 4.1 | RemoteRPCClient に `muxVia: String?` パラメータ追加 (NWConnection unix endpoint) | Sources/Belve/Services/RemoteRPCClient.swift | +30 | 中 |
| 4.2 | `registerControlMux(projectId, host, projShort)` 追加 | Sources/Belve/Services/RemoteRPCClient.swift | +20 | 低 |
| 4.3 | ProjectStore で mux flag に応じて分岐 | Sources/Belve/Services/ProjectStore.swift | +15 | 中 |

**完了基準**: mux 有効 host で file tree / git status / fsnotify push が動作

### Phase 5: 検証 + tuning + status UI (~1 日)

| # | task | 変更ファイル | 行数目安 | リスク |
|---|---|---|---|---|
| 5.1 | 50 pane × claude シナリオで MaxStreamWindowSize tune | tools/belve-persist/mux.go | +10 | 中 |
| 5.2 | `opTunnelStatus` 拡張: yamux session/stream 一覧 | master.go, mux.go | +30 | 低 |
| 5.3 | SettingsView に「Mux status」セクション | Sources/Belve/Views/SettingsView.swift | +50 | 低 |
| 5.4 | 本 doc を実装結果で更新 (= 実績 section) | docs/notes/2026-06-24-yamux-multiplex.md | +100 | 低 |

---

## 5. 不確実点 (要追加調査)

| # | 内容 | 調査方法 | 着手 phase |
|---|---|---|---|
| U1 | yamux の実メモリ使用量 (50 stream × 16 MiB 設定) | claude を 30 分動かして RSS 測定 | Phase 5 |
| U2 | sshd の真の channel 上限 (MaxSessions / MaxStartups / kernel limit のどれか) | 50 pane 開いた時の `/var/log/auth.log` 取得、`ss -s` の peak 観察 | Phase 0 (着手前) |
| U3 | yamux.Stream の SetReadDeadline 精度 | bufio.Reader で preamble 読む既存ロジックが流用できるか手動検証 | Phase 1 |
| U4 | Control RPC `registerControlPort` の呼び出し元 | `ProjectStore.select` 周辺と推測、要 read | Phase 4 |
| U5 | belve-mux-listener-*.sock の lifecycle | 削除した project の listener teardown 戦略 | Phase 2 |
| U6 | macOS Unix socket の send buffer (PTY 1byte write 耐性) | 計測 ([2 KiB?] / setsockopt 必要?) | Phase 2 |
| U7 | yamux session CloseChan の挙動 | goroutine leak の有無を pprof で確認 | Phase 2 |
| U8 | 「mux 有効 host で 19201 forward が refused」時の UX 文言 | XTermTerminalView のエラー path に統合、要レビュー | Phase 3 |
| U9 | yamux と replay buffer chunk (512 KiB) の相互作用 | 大きい replay でも perf 劣化しないか計測 | Phase 5 |
| U10 | `BELVE_MUX_TRACE=1` のログ rotation | 開発時のみ手動 enable とするか log rotate するか | Phase 1 |

---

## 6. ロールバック

| 段階 | 戻し方 |
|---|---|
| Phase 0-1 まで適用 | 何もしない (= 新 path コードは入ってるが未使用) |
| Phase 2-3 まで適用、運用前 | `AppConfig.mux = MuxConfig()` で default に戻す |
| Phase 2-3 適用、運用中に問題発覚 | `mux.hosts` から該当 host を削除 (= その host だけ旧 path に戻る) |
| Phase 4 まで適用、control RPC で問題 | 同上 (= host 単位 opt-out) |
| 全体撤回 (= 新 path コードごと削除) | `git revert` 連発 + binary 再 deploy (md5 mismatch で自動更新) |

---

## 7. オープン項目

着手前に決める必要あり:

- [ ] U2: sshd の真の上限を確定 (= MaxSessions=100 で本当に解決するなら yamux 不要かもしれない)
- [ ] Phase 5 まで全部やるか、Phase 3 で止めて様子見るか (= control RPC は同時接続数が少ないので channel への寄与が小さい)
- [ ] mux 有効化のロールアウト粒度 (host 単位で OK か、project 単位もありか)

着手中に決める:

- [ ] muxHostSlug の hash 関数 (sha1 / fnv / first-8-chars)
- [ ] yamux.Config の最終 tune (Phase 5)
- [ ] mux status UI の見せ方 (Phase 5)

---

## 8. 関連 doc

- `docs/notes/2026-04-22-broker-architecture-redesign.md` — Phase B (forward 1本化) の動機・設計
- `docs/notes/2026-04-23-mac-master-design.md` — mac-master daemon の役割
- 本 doc — Phase 6 (channel 1本化)
