# セッション永続化: belve-persist vs tmux（再検討）

**更新**: 2026-07-19
**ステータス**: 方向性決定（tmux を belve-persist の下に敷く方向で検討を進める）／プロトタイプ未着手

## きっかけ

VM 上の tmux が `terminal does not support clear` で落ちる問題（真因は VM broker が
`TERM=dumb` を session に伝播していたこと。`belve-persist` 側で `TERM=xterm-256color`
を権威固定して解消済み → commit `fix(persist): pin TERM=xterm-256color for broker session PTY`）
を直した流れで、「そもそもなぜ tmux でなく自前 broker なのか」「今から tmux 前提に
寄せる余地はあるか」を再検討した。

## 元の意思決定（記録が薄いので明文化）

明示的な「tmux をこの理由で却下した」ドキュメントは残っていなかった。ノート群
（`docs/todo.md`, `CLAUDE.md`, `2026-04-15-persist-tcp-migration.md`,
`2026-04-22-broker-architecture-redesign.md`）は *目標* として「tmux 依存を排除」と
書くのみ。コード／設計から読み取れる意図は以下。

1. **Full PTY passthrough（干渉ゼロ）**: `main.go` 冒頭 `no mouse/OSC interference`。
   tmux は端末ストリームをパースして再描画する多重化レイヤで、独自 screen モデル・
   ステータスライン・prefix キーバインド・マウス/OSC 横取りが入る。リッチ TUI
   (Claude Code) を素の xterm.js に素通しするため、その変換層を排除した。
2. **transport/control と一体設計**: mac-master → yamux router → per-container/VM
   broker、control RPC（git/file ops を 19224 で同一チャネル）、port-forward(19226)、
   replay buffer / VT snapshot による瞬時 reconnect、pane PID、OSC agent 通知。tmux は
   この control プレーンを提供しない。**tmux は永続化しか担えず、belve-persist の
   丸ごと置換にはならない**。
3. **docker exec 崩壊対策の TCP broker 化**（PTY 4層→2層、SIGKILL 自動 respawn）。

## 論点の分解: 2つの動機は別物

- **(1) 外部 tmux クライアントからの attach**（iOS の SSH ターミナルアプリ等で、PC で
  やってた作業を引き継ぐ）→ **tmux でしか得られない**（ワイヤプロトコル互換が要る）。
- **(2) belve-persist 更新でセッションが初期化される UX を無くす** → **tmux でなくても
  解ける**。機構: `belve-setup` が binary の md5 差分で broker を kill→再起動し、broker
  が PTY と shell を自分で保持しているため broker 再起動＝shell 初期化。痛点は「更新
  頻度の高い broker コードが PTY 保持プロセスを兼ねている」構造。PTY 保持を極小・不変の
  holder に分離し broker はそこへ attach するだけ、にすれば shell は生き残る（dtach/
  abduco/tmux のモデル）。

## トレードオフ評価（本人判断込み）

tmux を **belve-persist の *下* に敷く**形（belve-persist が shell を直接 spawn する
代わりに `tmux new-session -A -s <name>` に attach。transport/control/mux は温存）で検討。

| 懸念 | 評価（2026-07-19 時点の本人判断） |
|---|---|
| TERM/terminfo/色（tmux 内は tmux-256color、truecolor/OSC52 は要設定） | **許容**。色系は問題にならない見込み |
| resize が最小クライアント合わせ | **非問題**。同時編集はしない。PC→iOS の引き継ぎ用途で完全同時 attach を想定しない |
| 再描画コスト（tmux の repaint × xterm.js パーサ律速 0.5〜1MB/s） | **実質非問題**。重いのは「TUI 起動中のライブ resize」だけで用途外。attach 時 repaint は画面1枚ぶんで、現状の replay(最大4MiB)送出より**むしろ軽い**。純粋なパーサ律速は native VT(SwiftTerm)移行で別途改善可能 |
| replay を tmux に委譲 | **むしろ利点**。自前の VT snapshot / 4MiB replay buffer を捨てられ、描画ロジックが単純化 |
| 得るもの | 外部クライアント attach（(1) の本命）、実績ある永続化、replay 実装の削減 |

## 決定（方向性）

- **(1) と (2) を混ぜないのが肝**。(2) だけなら tmux は過剰（holder 分離で足りる）。
- 本件は **(1) モバイル引き継ぎが欲しい** ので、**tmux を holder として belve-persist の
  下に敷く方向**で進める。belve-persist は transport/control/mux レイヤとして残す。
- 上記トレードオフは許容と判断（色OK・resize用途外・redraw実質非問題・replay委譲は利点）。

## 次アクション（未着手）

1. 最小実験: `session-bootstrap.sh` の shell 起動を `exec tmux new-session -A -s belve-<pane>`
   相当に差し替え、1プロジェクトで体感（色/OSC52/undercurl、attach/reconnect の速度）。
2. 外部から `tmux attach -t belve-<pane>` が別 SSH 経由で刺さるか確認（(1) の検証）。
3. tmux 設定の詰め: `default-terminal`/`terminal-features`（truecolor）, `allow-passthrough on`,
   `set-clipboard on`（OSC52）, escape-time など。
4. replay 委譲に伴い belve-persist 側の replay buffer / VT snapshot を段階的に縮退できるか設計。
5. 別トラック: xterm.js → native VT パーサ（SwiftTerm）移行はパーサ律速の本命レバー
   （`2026-04-19-terminal-perf.md` 選択肢A）。tmux 化と直交。

## 関連

- `2026-04-15-persist-tcp-migration.md` — TCP broker 化の経緯
- `2026-04-22-broker-architecture-redesign.md` — broker 配置
- `2026-04-19-terminal-perf.md` — xterm.js パーサ律速と native 移行の選択肢
- `2026-06-24-yamux-multiplex.md` — mux router
