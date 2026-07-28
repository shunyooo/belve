# Networking 基礎まとめ — NAT / VPN / Tailscale / TCP/UDP

> 2026-04-29 の学習メモ。Belve の SSH port forward 起因のバグ修正をきっかけに、
> 「なぜそもそも port forward が必要か → NAT → IPv4 不足 → 妥協の積層」 と
> 掘り下げて、Tailscale / WireGuard までを 1 本の物語で整理した記録。

---

## 全体の物語 (= 1 段落で)

IPv4 のアドレス空間 (= 42 億) が device 数に対して足りない → **NAT** で「内側
private IP を 1 個の public IP に集約」する妥協が生まれた → 結果「外から内
への接続が原則できない」世界に → でも P2P や remote access はやりたい →
**STUN / hole punching** で NAT を騙す技を発明 → これらを束ねて使いやすく
した **VPN (= Tailscale, WireGuard)** が現代の答え → ただし TCP の重い
handshake は NAT 越えと相性悪いので **UDP** が事実上の標準。Belve の今夜の
port forward 起因の cascade バグも、根は **「NAT 後ろの 2 device を繋ぐ
苦労」** という同じ系譜の問題。

---

## 1. NAT (Network Address Translation)

### 1.1 何を解決してるか
- IPv4 = 32 bit (= 42 億個)、世界の device 数 (= 数百億) に圧倒的に不足
- 解決: 内側で **private IP** (= 10/8, 172.16/12, 192.168/16) を使い、router で
  1 個の **public IP** に集約

### 1.2 NAT table = router 内の翻訳テーブル

| 外側 (public) | 内側 (private) | 接続先 (peer) | TCP state |
|---|---|---|---|
| 60001 (UDP) | 192.168.1.20:55555 | 142.250.x.x:443 | ESTABLISHED |

- **NAT table を持つのは router** (= LAN の境界装置)。LAN 自体や Mac は持たない
- entry 1 行 = 1 つの「hole」
- idle timeout (UDP: 30-120 秒、TCP: 数時間) で消える

### 1.3 Port が device の最終識別子

- IP だけでは内側 device を区別できない (= 全部 1 つの public IP に潰される)
- **port** で区別する: `(public IP : port)` ペアが session の住所
- port は **NAT が動的割り当て** (= 内側 device が outbound packet 出した瞬間)

### 1.4 NAT 種別 (= 4 種類、router の firmware で決まる)

| 種別 | entry の key | filter | hole 共有 |
|---|---|---|---|
| **Full Cone** | (内 IP : 内 port) | なし | 誰でも通れる |
| **Restricted Cone** | (内 IP : 内 port) | dst IP 制限 | 同一 IP からのみ |
| **Port-Restricted Cone** | (内 IP : 内 port) | dst (IP, port) 制限 | 同一 (IP, port) からのみ |
| **Symmetric** | (内 IP : 内 port, 外 IP : 外 port) | entry 自体が dst-specific | dst ごとに別 port |

- 厳しいほど外部 attack に強い、でも P2P が困難
- **ユーザーは大抵変えられない** (= router firmware 固定)
- 世の中は Symmetric が増加中 (= 家庭, mobile, cloud NAT 全部)

---

## 2. 「Port が外から見える」 = 通信した相手にだけ

### 2.1 TCP/UDP header の中身
- 全 packet に `src IP, src port, dst IP, dst port` の 4-tuple が必ず入ってる
- **受信した側は無条件で src を見れる** (= protocol 不問)
- HTTP server も access log で `$remote_addr:$remote_port` を取れる

### 2.2 STUN は「教えてあげる」だけ
- STUN server は「あなたが俺と話してる時の外側 IP/port は X:Y」と返答するだけ
- NAT が割り当てた port を **明示的に echo back** してるだけで、特別な発見はしてない
- Application 層では普段意識しないが、HTTP でも同じ情報は受信側で取れる

### 2.3 第三者は知れない
- random ephemeral port (49152-65535)
- 通信した相手しか具体値を知らない
- 65535 個から無関係な攻撃者が当てるのは現実的に困難 → **NAT は意図せず firewall**

---

## 3. NAT は「外向き → 内向き許可」を暗黙宣言する stateful firewall

### 3.1 「サーバに繋いだ瞬間に hole が開く」のは事実
- Mac → malicious.example.com:443 アクセス
- 家 router が NAT entry 作成 (= filter: malicious-IP:443)
- → サーバは追加 packet を Mac の hole に投げ込める

### 3.2 でも別口攻撃が成立しにくい理由

| 防御 | 内容 |
|---|---|
| NAT TCP state tracking (= conntrack) | ESTABLISHED 中の新 SYN は drop、seq 範囲外も drop |
| Hole は session-bound | 別 connection を hole 経由で開けない |
| Browser sandbox | JavaScript の能力制限、cross-origin 阻止 |
| TLS | server 識別 + 暗号化 |
| App layer 認証 | physical に届いても session 開けない |

つまり **「session 内 (= browser tab 内) で何か仕掛ける」しか実用攻撃面が無い**
状態になってる。

### 3.3 例外 (= 実在する高度攻撃)
- **NAT Slipstreaming** (2020): JavaScript で NAT の ALG を騙して追加 hole 開く
- **DNS Rebinding**: domain → local IP に書き換えて internal service にアクセス
- **UPnP abuse**: malware が UPnP で自身を外部公開
- いずれも対策が browser / NAT 側で進行中

---

## 4. P2P / Hole Punching

### 4.1 P2P = 「中継サーバなしで device 同士が直接通信」

仲介役 (= STUN server) は最初の **「自分の外側 IP/port」発見** に必要。
データは仲介を経由しない。

### 4.2 Hole punching の核心

```
[両端が同時に互いの外側に packet 投射]

時刻 t=0
  Mac → VM の外側 (198.51.100.30:50002) に packet
  VM → Mac の外側 (203.0.113.42:60001) に packet  ← 同時

各 NAT: 「内側から出た packet あり、その相手からの返事は通そう」
   → table に entry 作成 = hole 開く

時刻 t=10ms
  Mac の packet が VM の NAT 通過 ✓
  VM の packet が Mac の NAT 通過 ✓
  → 双方向通信成立
```

### 4.3 「同時に」が必要な理由
- 片方だけ送っても、相手側の NAT に entry がない → drop
- Coordination server (= 鍵管理 + 同期役) が「今打て」を両端に同時通知
- UDP は単発 packet なので timing 失敗のコスト低、retry も簡単

### 4.4 Symmetric NAT どうしは punching 不可
- dst ごとに外側 port 変わる → STUN で得た port が peer 通信用と違う
- → DERP relay 経由 fallback

---

## 5. Tailscale = mesh VPN

### 5.1 構成要素

| 要素 | 役割 | データ流す? |
|---|---|---|
| **Coordination server** | SSO 認証 + 公開鍵配布 + ACL 配信 + device 一覧 | ❌ |
| **DERP server** | STUN (= 自分の外側を教える) + TURN (= P2P 失敗時 relay) | 必要時のみ、暗号化されたまま中継 |
| **WireGuard** | 実際のデータ平面、暗号化 UDP tunnel | ✅ (= 中身) |

### 5.2 認証 / 接続フロー

```
1. tailscaled が WireGuard 鍵ペア生成 (= 秘密鍵は端末から永久に出ない)
2. ブラウザで SSO (Google/GitHub/etc.)
3. 公開鍵 + device メタを Coordination に登録
4. Coordination が peer の公開鍵 + endpoint candidate を返す
5. disco protocol で path probing (= LAN/STUN/DERP の各 candidate 並列試行)
6. 最良 path で WireGuard handshake → established
7. 25 秒間隔の keepalive で hole 維持
```

### 5.3 SSO / ACL
- **SSO**: 「あなたは誰?」 = 認証 (= Authentication)
- **ACL**: 「あなたは何ができる?」 = 認可 (= Authorization)
- Tailscale ACL は **device + user + port レベル** で細かく書ける

### 5.4 DERP の二刀流
- 名前: Designated Encrypted Relay for Packets
- HTTPS / TCP 443 ベース → 厳しい firewall 突破力高い
- STUN 機能 (= 自分の外側 IP/port 発見) + TURN 機能 (= relay fallback)
- 中継するパケットは暗号化されたまま、Tailscale 社にも中身は見えない

---

## 6. WireGuard = Tailscale の「エンジン」

| 要素 | WireGuard | Tailscale |
|---|---|---|
| 役割 | 暗号化 UDP tunnel (= データ平面) | Orchestration (= 鍵配布 + NAT 越え + ACL + UI) |
| サイズ | ~4000 行のコード | WireGuard を含む大きい package |
| 設定 | 全 peer の公開鍵 + IP を手動 config | Coordination が全自動 |
| 認証 | 公開鍵のみ | SSO + 公開鍵 |

WireGuard 単体でも VPN は張れるが、運用の手間 (= 鍵配布、NAT 越え、ACL) を
Tailscale が肩代わりしてる関係。「**エンジン (WireGuard) + 完成車 (Tailscale)**」
の比喩。

---

## 7. TCP vs UDP

### 7.1 責務の置き場の違い

> 「TCP は信頼性の責務を transport 層に置ける、UDP は application が責任持つ」
> ← 今回の対話で出た user の表現、本質的に正解

| | TCP | UDP |
|---|---|---|
| Connection | 必要 (3-way handshake) | 不要 |
| 信頼性 | ◎ 全 byte 必ず届く | ✗ best-effort |
| 順序 | ◎ | ✗ |
| 速度 | △ overhead 多い | ◎ 軽量 |
| Header | 20-60 byte | 8 byte |
| 用途 | HTTP/SSH/DB 等 | DNS/VoIP/game/VPN 等 |

### 7.2 TCP 3-way handshake

```
Client → Server: SYN  (= 接続したい、私の ISN は X)
Client ← Server: SYN-ACK (= OK、私の ISN は Y、あなたの X 受領)
Client → Server: ACK (= Y 受領、開始)
   ↓
ESTABLISHED → 双方向 byte stream
   ↓
Client → Server: FIN  (= 切ります)
Client ← Server: FIN-ACK
   ↓
CLOSED
```

### 7.3 SYN とは
- TCP header の制御フラグ 1 個 (= 6 個ある中の 1 つ)
- 「接続したい」の意思表示
- SYN/ACK/FIN/RST が主要な flag

### 7.4 Sequence Number の役割
- **byte 単位の通し番号** (= 各 byte に番号が振られる)
- 機能:
  1. handshake で ISN 同期 = 「以後の通信の合意基準点」
  2. 順序復元 (= packet 入れ替わり対応)
  3. 損失検出 (= ACK で「seq X から欲しい」と要求)
  4. Security (= ISN を random 化することで session hijack 防止)

### 7.5 なぜ UDP の方が hole punching しやすいか

| 要因 | UDP | TCP |
|---|---|---|
| Handshake | 不要 | 3-way 必要 (= simultaneous open しか道なし) |
| State machine | ほぼ無し | 厳格 |
| 「不審 packet」判定 | 緩い | 厳しい (= SYN flood 対策で外向き SYN drop) |
| OS 実装の差 | 影響少 | simultaneous open 未対応 OS 多い |
| Timing 制約 | 緩い | シビア |
| 失敗 retry | 単純 | 複雑 |

成功率実測: UDP **80-90%** vs TCP **40-60%**。

「**TCP の重装備が NAT を通り抜ける時に引っかかる、UDP の軽さが NAT 越えに有利**」
が一文の答え。

### 7.6 UDP 上に再実装する流儀
- **QUIC** / **HTTP/3** = UDP 上に TCP 的信頼性 + TLS + multiplexing を自前実装
- **WireGuard** = UDP 上に独自暗号 protocol
- **WebRTC DataChannel** = UDP 上の SCTP-like
- 共通動機: 「UDP の軽さ + NAT 越え易さ」 を活かしつつ、必要な性質だけ自前で
  作る。OS/kernel に依存せず application で配れる利点もデカい。

---

## 8. Belve への当てはめ

### 8.1 今夜の cascade バグの根本原因
- Master daemon の port forward 管理 (= state 不安定 → master 再起動で全 pane 切断)
- SSH MaxSessions 圧迫 (= silent fallback で SSH を爆食い)
- encMu lock 詰まり (= 巨大 untracked file の content を NDJSON で返してた)

### 8.2 全部 NAT/SSH 起因
- Mac から VM の private IP に直接届かない (= NAT 後ろ)
- → SSH port forward で Mac の local port を VM の port に翻訳
- → port allocation / 永続化 / forward 管理 / SSH session 数の苦労
- → 今夜の各種バグ

### 8.3 Tailscale 化で構造ごと消える
- Mac と VM が同じ tailnet にいれば、`100.20.30.40:19200` に直接 TCP
- port forward 概念ごと消滅
- 「**transport を SSH → Tailscale に差し替える 1 行**」で済むのは、Belve の
  router 集約型 architecture (= 全 ops が VM:19200 に通る) のおかげ
- naive に「全 op を SSH に直書き」してたら大改修だった

### 8.4 hybrid 移行が現実的
- Setup phase (= binary deploy 等) は SSH 維持
- Runtime phase (= PTY / RPC) だけ Tailscale 化
- Project 単位で「Tailscale 使う/使わない」選べる設計

---

## 9. 気になった / 印象的だったポイント (= 学習中に出た insight)

### 9.1 「port は IP 不足の workaround」
- IPv4 が device 数に足りない → 1 個の public IP を内側 device 数百で共有
- port で区別 → 「**理想的にきれいな状態じゃなく、規格に合わせた駆逐の産物**」
  という認識は完全に正解
- IPv6 (= 128 bit) なら NAT は不要だが、普及率 40% で IPv4 + NAT が支配的なまま

### 9.2 「サーバ接続 = 暗黙の hole 開け」 = security 上の認識
- 普通の web 閲覧でも hole が開いている事実は驚きだった
- でも実用攻撃面は browser sandbox + TLS + NAT TCP state で多重防御
- NAT は **意図せず session-aware firewall** になってる、というのは隠れた基盤

### 9.3 「Port 443 限定」の脆弱性軽減効果は限定的
- port 番号は単なる識別子、何 protocol を listen させるかは app 開発者の自由
- HTTPS が安全に「見える」のは port のおかげじゃなく **TLS + browser sandbox**
- 攻撃者が同じ port 443 から WebSocket / chunked / HTTP/3 / browser exploit 等で
  ほぼ任意の悪意ある通信ができる
- 「port 限定」は攻撃者集団の中で「1 人に絞る」効果しかなく、その 1 人の悪意は
  別 layer で防ぐしかない

### 9.4 「順番にやれば」が NAT で成立しない罠
- 直感的には「Mac が SYN 先送る → VM 応答」 で良さそう
- でも VM の NAT に entry がないので Mac の SYN は drop される
- → VM が応答できない → デッドロック
- だから simultaneous open (= 両方が同時に SYN) しか道がない
- Coordination server が「今打て」を両端に同時通知する役割

### 9.5 Sequence Number = 合意 + 番号付け + Security
- ご認識の「**通信成立の合意**」は ISN 交換の意味で正解
- 加えて、以後の byte stream 全体の整合性 (= 順序 / 損失 / 再送) も司る
- ISN を random 化することで session hijack 防止 = security も担う

### 9.6 「TCP/UDP の違いは責務の置き場」
- TCP: transport 層が信頼性 / 順序 / handshake を全部引き受ける、app は楽
- UDP: transport は datagram 投げるだけ、app が必要に応じて自前で
- 単に「速い/遅い」じゃなく、**「責任の境界線」を選ぶ判断**

### 9.7 「TCP 重装備が NAT 越えに不利」が逆説的
- TCP の handshake / state machine が安全性のために重い
- でもその重さが NAT の hole punching と相性最悪
- → 現代の P2P / 低遅延 protocol が全部 UDP ベースに collapse する根本理由
- 「**信頼性と NAT 越え易さがトレードオフ**」という非自明な結論

### 9.8 WireGuard / Tailscale / DERP の関係
- WireGuard = エンジン (= 暗号化 UDP tunnel)
- Tailscale = 完成車 (= WireGuard を運用しやすくした wrapper)
- DERP = STUN + TURN 兼任の地理分散中継 (= P2P の最終 fallback)
- 「Coordination は鍵配布だけ、データ流れない、Tailscale 社にも中身見えない」
  という分業構造で trust 最小化されてる

---

## 10. 用語集

| 用語 | 一言で |
|---|---|
| **NAT** | private IP ⇄ public IP 翻訳。1 個の public IP を内側 device 多数で共有 |
| **Port** | (IP : port) で device を区別する識別子。NAT が動的割り当て |
| **NAT table** | router 内の翻訳記憶。entry 1 行 = 1 つの "hole" |
| **Conntrack** | NAT が TCP state を tracking する機能。stateful firewall を兼ねる |
| **Hole** | NAT table の 1 entry。idle timeout で消える |
| **Hole punching** | 両端同時 packet 送信で NAT に hole 開ける技 |
| **STUN** | 「あなたの外側 IP/port は X」 と教えるだけの軽量 server |
| **TURN** | STUN 失敗時に全 traffic relay する重量 server |
| **DERP** | Tailscale 独自の STUN + TURN 兼任。HTTPS/TCP 443 ベース |
| **VPN** | public internet 上に暗号化 tunnel を張って virtual な private network 作る |
| **Mesh VPN** | 中央 hub なしで device 間 direct tunnel。Tailscale 等 |
| **WireGuard** | 軽量 modern VPN protocol。UDP + 公開鍵認証 + 簡素設計 |
| **Tailscale** | WireGuard + Coordination + DERP + SSO + ACL の完成 service |
| **Coordination server** | 鍵配布 + ACL 配信。データには関与しない |
| **SSO** | 認証 (= 「あなたは誰?」) を IdP に委譲 |
| **ACL** | 認可 (= 「あなたは何ができる?」) のルール一覧 |
| **TCP** | connection-oriented、信頼性、順序保証、3-way handshake |
| **UDP** | connectionless、best-effort、速い、軽い、自前 protocol 必要 |
| **SYN** | TCP の「接続開始したい」フラグ。3-way handshake の最初 |
| **Sequence Number** | byte 単位通し番号。順序復元 / 損失検出 / session hijack 防止 |
| **Simultaneous open** | TCP で両端が同時 SYN 送る稀な状態。hole punching に必須だが OS 実装弱い |

---

## 11. 参考にしたい / 深堀りすべき次のテーマ

- **Tailscale 公式 blog** (= NAT 越えの仕組み解説が秀逸): tailscale.com/blog
- **WireGuard whitepaper**: wireguard.com/papers/wireguard.pdf
- **STUN/TURN/ICE の RFC** (= RFC 5389, 5766, 8445)
- **TCP/IP Illustrated** (= W. Richard Stevens、networking の bible)
- **High Performance Browser Networking** (= Ilya Grigorik、無料 web 公開)
- **NAT Slipstreaming** の研究論文 (= Samy Kamkar)

Belve 関連:
- 本リポジトリの SSH / port forward 周辺コード (= `tools/belve-persist/tunnel.go`,
  `Sources/Belve/Services/MasterClient.swift`, `RemoteRPCClient.swift`)
- 移行検討時には `docs/notes/` に Tailscale 化設計の note を追加予定
