# Belve.app 再起動時の PTY 接続カスケード

作成日: 2026-04-22
ステータス: 既知の問題、根本対応未着手 (= 暫定で許容中)

## 症状

Belve.app を再起動 (= 開発中の rebuild + restart、もしくはユーザー手動 quit)
すると、全 PTY ペインが一斉に切断され、再接続が完了するまで数秒〜数十秒
「全ターミナル frozen」状態になる。

```
22:42:26  全 Mac belve-persist client が "socket-read: EOF" で exit
22:42:34-37  daemon に新しい client が attach (12+ panes 順次)
```

この間、ユーザーには PTY が応答しないように見える。

## 現状の構造

```
Belve.app
  └── posix_spawn (POSIX_SPAWN_SETSID)
        └── belve-persist (client mode)         ← Belve の子
              ├── tryAttach to /tmp/belve-shell/sessions/$NAME.sock
              └── (no daemon) → spawnDaemon():
                    └── exec "belve-persist -daemon" (Setsid + Release)
                          └── belve-persist (master daemon)  ← detached, survives Belve death
                                └── tcpbackend → router → broker → PTY
```

- **daemon** (master mode) は detach 済み (`Setsid: true` + `cmd.Process.Release()`)
  → Belve.app 死んでも生存
- **client** (PTY 内のプロセス) は Belve.app が spawn した子プロセス。
  Belve 死亡時に PTY master fd が close される → client の stdin に EOF
  → client 終了

新 Belve.app:
- 新しい client を per-pane で再 spawn
- client は tryAttach で既存 daemon に接続 → 生きてる PTY セッションに復帰
- daemon の replay buffer が送られて scrollback 復元

→ 再接続は機能する。が、12+ panes 順次 + JS 側初期化 + scrollback 描画 で
**数秒〜数十秒の不安定期間**が出る。

## 根本対応の選択肢

### A. Client プロセスを廃止 — Belve.app が直接 daemon socket を叩く (推奨)

```
Belve.app
  └── Unix socket connect to /tmp/.../$NAME.sock
        └── daemon ← 既存
```

- client (= PTY ラップ) を介さず、Belve.app が直接 daemon の Unix socket を
  open + I/O
- 再起動時に Belve.app が socket を再 open するだけで OK
- xterm.js には Swift から socket データを直接 evaluateJavaScript で送信
- 入力も逆方向で socket に直接 write

メリット:
- プロセス階層が浅くなる (16 panes = 16 client プロセス削減)
- 再起動時の不安定期間が解消 (再 connect だけ、socket は kernel 持ち)
- I/O ホップが減って per-keystroke latency も微減

デメリット:
- PTY 系コードの大改修
- Swift 側で belve-persist の socket protocol (msgData / msgSession 等) を再実装する必要
- 既存の `tryAttach` ロジック (再接続) を Swift 側に移植

工数: 2-3 日

### B. Client プロセスも detach (中間案)

- spawn 時に SETSID + setpgid + ignore SIGHUP で client を完全 detach
- Belve.app 死亡後も client は生存
- 新 Belve は **既存 client に再接続** する (= client が Belve.app 用に
  IPC port を listen)

デメリット:
- Belve.app 1 つに対して client が 16 個 detach されたまま — リソース食う
- 新 Belve が「正しい client」を見つけるためのレジストリ必要
- アンインストール時の clean up 厳しい

→ 採用しない。A の方が根本的。

### C. 現状維持 + 再起動感を緩和 (痛み止め)

- 全 pane 同時に再 attach するのではなく、**active project の pane を
  優先順位高め** に並列度制限つきで attach
- Loading overlay を見せて「再接続中」を明示

→ 体感は改善するが本質的じゃない

## 関連する暫定 fix

- `8b3b50286f4` (md5 mismatch で broker kill しない) — broker 側の churn は
  止めたが、client/daemon の Belve 子問題は別

## 進捗

- [x] 問題の特定 + ログ確認
- [x] Daemon は SETSID 済 (生存) を確認
- [ ] A 案の設計詳細
- [ ] Belve.app から socket protocol を直接喋る API
- [ ] xterm.js データ流の Swift→JS bridge

## 関連ファイル / 過去ドキュメント

- `Sources/Belve/Services/PTYService.swift` (= PTY spawn 元、posix_spawn)
- `tools/belve-persist/main.go`:
  - `spawnDaemon` (line 1040 付近、`Setsid: true`)
  - `tryAttach` (再接続ロジック)
  - `runMaster` (daemon 本体)
- `docs/notes/2026-04-22-broker-architecture-redesign.md` (Phase B 全体)
- `docs/notes/2026-04-22-broker-version-negotiation.md` (broker 側の更新問題)
