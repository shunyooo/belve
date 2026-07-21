# Belve — エージェント司令塔への転換（製品定義・UX・実装デルタ）

**更新**: 2026-07-21
**ステータス**: 方向確定・実装未着手
**モック**: https://claude.ai/code/artifact/f9ac7c3b-68be-4733-8699-04bbf7c3f7a5

## TL;DR

Belve を「DevContainer 特化の開発環境」から **「マルチプロジェクトのエージェント（Claude）
セッションを、人間が状態を見て指令する司令塔」** に再定義する。差別化は **コード/Markdown を
ちゃんと見れるエディタ/プレビュー（レビュー体験）**。リライトではなく **再オリエンテーション＋簡素化**
で、UI シェル・可変ペインは据え置き、実装の重心は「エージェント状態モデル」1点に集約される。

## 背景：開発形態の変化（2026-07 中旬〜）

- 旧: DevContainer の中に入って作業。痛点＝コンテナ内に tmux を入れる／Tailscale 等の設定を
  コンテナ内でやる、といった「コンテナ内を第一級環境にするコスト」。
- 新: VM の**素の SSH** でソースフォルダに入り、そこで **tmux → Claude** を立て、プロジェクトを
  指定して働かせる。Docker がある系も検証は **Claude Code セッションの中**（テスト実行等）で完結。
  コンテナには Belve が入らない。
- → Belve は「一元的に使えるエージェント司令塔」へ。

## 製品定義（北極星）

> 複数プロジェクトのエージェントセッションを、人間が状態を見て指令する司令塔。
> 差別化は「コード/Markdown をちゃんと見れるエディタ/プレビュー」。

herdr 等の端末ネイティブ勢が「セッション管理・状態可視化」をやる中で、Belve の勝ち筋は
**レビュー体験**（diff・シンタックスハイライト・Markdown レンダリングでエージェントの成果を見れる）。

## 主要な設計判断

- **描画は tmux に任せる（通常モード）／control mode は不採用**。control mode（`tmux -CC`、
  iTerm2 方式）はクライアント側で replay/スクロールバックを自前実装する必要があり、そこが重い。
  tmux にスクロールバック/永続化を全部持たせる方が実装が軽い。
- **対話レイテンシは当面許容**。原因は「tmux の再描画出力を xterm.js の遅パーサ(0.5〜1MB/s)が
  捌けない」こと（素シェルは速い／Ghostty は速い＝xterm.js × tmux の組合せだけ遅い）。根治は
  **native VT パーサ（SwiftTerm）移行**で、これは別トラックの将来レバー（`2026-04-19-terminal-perf.md`）。
  司令塔は「打ち込む」より「見て指令する」ので通常モードで許容可、と判断。
- **コンテナ経路は二級化 → 段階的一掃**。新パス（VM+tmux）が日常を置き換えたのを確認後、専用
  コミットで削除。維持が重くなれば即削除。**今すぐ投資停止**：port-forward WIP（forward.go 等）と
  static-tmux-in-container は破棄/凍結。
- **belve-persist の VT snapshot / serialize-restore は撤去**（スクロールバックは tmux が持つ）。
  bounded replay（256KB、再接続時の現在画面復元）だけ残す。
- **herdr 評価済み・不採用**（差別化がエディタ/レビュー。herdr は AGPL・独自 attach プロトコルで
  iOS 非対応・UI が opinionated）。アイデア源（agent 状態検出・socket API）としてはウォッチ。
- **外部 attach は Mosh + tmux**（`mosh <vm> -- tmux attach -t belve-<pane>`）。PC↔iOS 引き継ぎ。

## UX 骨格（モック参照）

実機の凝った chrome を維持：**full-height サイドバー（左端・上から下まで）＋ 右側だけが
プロジェクト固有エリア**。

- **サイドバー（全高）**: traffic lights を上部に。**プロジェクト（安定・上）→ 各セッションを状態
  ドット付きで**、**要対応（揮発・下）**。揺れる要対応を下にして上の安定エリアがガタつかない配置。
- **右・上バー**: プロジェクト/セッション名 ＋ `詳細 / 俯瞰` 切替 ＋ host チップ。
- **右・コンテンツ**:
  - **詳細**: 可変ペインで `指令(terminal) | プレビュー(Markdown/Diff/コード) | 右=ファイル`。
    右ファイル列は **`変更`（このセッションの git diff・新しい順）/ `ツリー`（全体・変更マーカー付）**
    をトグル。ツリーは実機同様に右端。比率は現状どおりドラッグ可変（固定ではない）。
  - **俯瞰**: 全プロジェクト×全セッションをカードで一望。並びは 要対応 → 作業中 → 完了 → 待機。
- **右・ステータスバー**: tmux・作業中/要対応数・レビュー元(git diff)・LSP。

状態は色＋形で符号化（pill/ドット/severity stripe）。アクセント=シアン1色、意味色（琥珀=作業中/
コーラル=要対応/緑=完了/灰=待機）はアクセントと分離。

## 実装デルタ（今のベースから何が変わるか）

| 区分 | 内容 |
|---|---|
| **維持** | full-height サイドバー chrome・上バー・ステータス・**可変ペイン**・エディタ(CodeMirror)・Markdown(Milkdown)・ファイルツリー・ターミナル(xterm.js)・belve-persist control RPC(git ops)・OSC 通知 |
| **変わる** | (1) サイドバー: プロジェクト配下に tmux セッションを状態ドット付きで（今は pane 中心）＝「セッション＋状態」を一級に。(2) プレビュー領域: ツリーに加え「変更」モード（session git diff・recency）を追加 |
| **新規** | **エージェント状態モデル**（working/blocked/done/idle を tmux セッション単位で追跡。OSC＋プロセス/出力解析）／俯瞰グリッド view（tile/stage の view-mode 基盤に）／要対応トリアージ／ChangedFilesStore（git diff RPC→recency） |
| **消える** | DevContainer データ経路（container broker・docker cp 配布・container terminfo・**port-forward relay**・mux の container ルーティング）／belve-persist の VT snapshot・serialize-restore／(native パーサ・control mode はやらない) |

**本質的に新しいのは「エージェント状態モデル」1点**。あとは既存部品の組み替えと削除。

## 実装計画（フェーズ）

- **P0（基盤）**: エージェント状態モデル ＋ `ChangedFilesStore`
  - 状態モデル: OSC 通知（`AgentNotificationTransport`）＋ プロセス名/出力解析で
    working/blocked/done/idle を tmux セッション単位に判定。
  - `ChangedFilesStore`: belve-persist control RPC（19224, git status/diff）を購読し recency 順。
- **P1（サイドバー）**: プロジェクト → セッション（状態ドット）を表示。要対応セクション（下部）。
- **P2（プレビュー）**: 右ファイル列に `変更 / ツリー` トグル。変更＝session diff、選択→既存
  エディタ/Markdown プレビューに連動。ツリー上に変更マーカー。
- **P3（俯瞰）**: 全セッション グリッド view（状態順）。カード→詳細への導線。
- **P4（簡素化）**: コンテナ経路の一掃／belve-persist の VT snapshot・serialize-restore 撤去。

## 関連

- `2026-07-19-tmux-vs-belve-persist.md` — tmux 移行の意思決定（VM+tmux 一元化）
- `2026-04-19-terminal-perf.md` — xterm.js が律速 → native パーサ（将来レバー）
- ブランチ `tmux-persist-experiment` — tmux holder ＋ bounded replay（＝通常モードの土台。
  実装済み・要 main 反映判断）
