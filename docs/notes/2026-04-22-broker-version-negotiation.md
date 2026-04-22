# Broker protocol version negotiation (planned)

作成日: 2026-04-22
ステータス: 設計合意済み、実装未着手

## 問題

`belve-persist` (broker) は container/VM に常駐してて PTY セッションを保持
してる。Belve.app を更新すると Mac 側の binary は新しくなるが、リモートの
broker は古いまま動き続ける。今までの挙動:

- launcher の `belve-setup` が起動するたびに md5 比較
- 不一致なら **broker を kill + 新 binary で respawn**
- → 全 PTY セッション切断 → reconnect カスケード (~30s 不安定)

開発中の頻繁な rebuild で特に酷く、ユーザー体感は「使えないアプリ」。

直近の暫定対応 (`8b3b50286f4`) で md5 不一致でも kill しないようにしたが、
逆に「新機能が反映されない」状態が起きる。

## 採用方針: A. プロトコル版数折衝

Mac client (= belve-persist の `-tcpbackend` モード) と broker が接続時に
バージョン番号を交換し、互換性に応じて挙動を切り替える。

### handshake 詳細

```
Mac 接続 → router → broker
最初に NDJSON 1 行で:
  → {"hello":"belve","version":"2.0","caps":["pty","control","watch"]}
broker から返信:
  → {"hello":"belve","version":"1.0","caps":["pty","control"]}
```

`version` は Belve.app のバージョン (semver)。`caps` は機能フラグ。

### 互換性判定

| broker version vs Mac version | 挙動 |
|---|---|
| 同じ | そのまま接続 |
| broker 古い & **同じ major** | そのまま接続 (機能差は noop で吸収可能) |
| broker 古い & **major 違う** = breaking | Mac が router 経由で `restart_broker` RPC 呼出 → router self-heal が新 binary で broker spawn → Mac 自動 reconnect |
| broker 新しい (= Mac が古い) | Mac client が「アプリ更新を促す」banner 表示 (致命的でなければ接続は続行) |

### 実装ポイント

1. `belve-persist` の PTY broker / control RPC: 接続最初の handshake message
   を読む。なければ legacy 扱い (= 旧プロトコル)
2. Mac client (`-tcpbackend` mode): 接続直後に hello を送る (preamble の後)
3. control RPC に `restart_broker` op 追加。router が docker exec で kill +
   spawn (= self-heal の手動トリガ)
4. Major version は Belve のリリースで管理。breaking 変更があった時のみ bump。

### マイグレーション (= 既存環境からの移行)

- 旧 binary は handshake を送らない/読まない → broker が無視 → 接続は普通に進む
- 新 binary は handshake を送るが、旧 broker が読まない → broker が次の
  メッセージとして PTY/RPC を解釈 → エラー or hang
  - 対策: handshake は **router の preamble の後ろ** に組み込む (router は
    新版なので handshake をパースする責務を持つ)。broker 側は変えない方法も
    あるが、broker が version を返せないと Mac が判定できない
  - もしくは: 古い broker は handshake が来ないと仮定 (= legacy)、新 broker
    は handshake を必ずパース。Mac は broker の応答ではなく自分の version
    と env で「broker は古い前提で動く」を判定

具体的には:
- Phase B router が中央集中で handshake 担当する形が綺麗
- router が Mac→broker の橋渡し時に handshake を仲介
- broker version は別経路 (= router が `belve-persist --version` を docker exec で
  問い合わせる) で取得

## サイドバイサイド (案 B) を採らない理由

- 新 broker を別ポートで起動 → 既存接続は旧 broker、新規は新 broker
- 旧 broker の接続が全部切れたら自動 exit
- セッション完全保護できる代わり実装が重く、route テーブル / 移行ロジックが複雑
- Belve のスケール感では oversize

## ユーザー判断 (案 C) も採らない理由

- 「Restart broker」メニュー項目で手動更新
- 一番楽だが、ユーザーに「broker」概念を意識させるのは UX 的にダメ

## 進捗

- [x] 暫定: md5 不一致で kill しないように (`8b3b50286f4`)
- [ ] handshake protocol 設計の最終 (フィールド名 / 互換ルール詳細)
- [ ] broker 側 handshake 実装
- [ ] Mac client 側 handshake 実装
- [ ] router 仲介 + `restart_broker` RPC
- [ ] migration テスト (旧 broker × 新 Mac, 新 broker × 旧 Mac)

## 関連

- `docs/notes/2026-04-22-broker-architecture-redesign.md` (Phase B 全体)
- `8b3b50286f4` 暫定 fix
- `tools/belve-persist/router.go` (router self-heal の流用元)
- `Sources/Belve/Resources/bin/belve-setup` (md5 check の現実装)
- `tools/belve-persist/main.go` (handshake 投げる側 = `runMasterTCPBackend`)
