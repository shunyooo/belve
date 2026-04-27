# Stage View 設計 (草案)

## 1. コンセプト

これまでの Project / Tile view は **同期監視型** = ユーザーが agent の動作をリアルタイムで見て随時指示する。

Stage View は **非同期 review 型** に切り替える:

- ユーザーが出すのは「要求」(タスク依頼)
- Agent は裏で勝手に進めて、終わったら **結果を報告** してくる
- ユーザーは 1 つずつ報告に対して「OK / 修正指示 / 次のアドバイス」をする
- ユーザーは agent の動きを「進捗」「ざっくり要約」レベルでだけ気に留める (= terminal そのものを凝視しない)

→ ユーザーの注意の単位が「pane」ではなく「報告 / Result」に変わる。

## 2. 名称候補

- **Stage** (Mac の Stage Manager 由来。確定でなければ別名も検討)
- 候補: Review / Stand-up / Briefing / Throne (= 玉座から指示)

仮に **Stage view** で進める。

## 3. UI モチーフ (Mac Stage Manager 風)

**1 card = 1 agent = 1 pane**。Request は別 entity として扱わず、agent の中の input として取り込む。

```
┌──────────────────────────────────────────────────────┐
│ TopBar                                               │
│                                                      │
│   ┌────┐                                             │
│   │ A  │ ◀── 走行中 agent                            │
│   └────┘    (左に縦並び浮遊)                         │
│                                                      │
│   ┌────┐    ┌──────────────────────┐                 │
│   │ B  │    │                      │                 │
│   └────┘    │   Center stage       │                 │
│             │   (review 中の agent) │                 │
│   ┌────┐    │                      │     ┌───┐       │
│   │ C* │    │  - summary           │     │ + │       │
│   └────┘    │  - changes           │     └───┘       │
│   ✓ ready   │  - terminal log      │   new agent     │
│             │  - input bar         │  (右下 FAB)     │
│   ┌────┐    │                      │                 │
│   │ D  │    └──────────────────────┘                 │
│   └────┘                                             │
│                                                      │
└──────────────────────────────────────────────────────┘
```

**特徴**:
- Off-stage agent card は左側に **縦並び浮遊** (固定 column ではなく自由配置)
- ✓ マーク (= report 提出済 / waiting) は強調表示 + 軽い pulse で「review してほしい」を表現
- Center stage は中央で大きく、agent の terminal + 報告 (summary) + ユーザー input bar を収める
- 右下に **"+ New Agent" FAB** = 新 pane を spawn して初期タスクを与える
- 既存 agent への追加指示 = center stage 下部の input bar から (= 既存の terminal 入力と同じ経路)

**アニメーション**:
- Off-stage card クリック → 中央へ **にゅっと拡大** (= matchedGeometryEffect で hero)
- 元 center にあった agent は左端の off-stage 列へ **しゅっと縮小**
- すれ違いは spring `(response: 0.4, dampingFraction: 0.75)` でリアルな物理感
- 新 agent spawn: 中央に scale-in でフェードイン (= 直ちに center stage へ)

## 4. データモデル (新概念)

既存の Project / pane / AgentSession に加えて、Stage view 用に追加:

### Report (任意 — Phase 2 以降で導入)
Agent の最後の発言 / 完了状態を構造化したもの。MVP では明示的 entity 不要、AgentSession.message と pane の最新 output で代替できる。

将来 (Agent 側にプロトコル仕込めたら):
- `summary`: 1-2 文要約
- `changes`: 触ったファイル一覧
- `proposedNextSteps`: agent からの次手提案

### StageViewState
- `centerPaneId: String?`: 今 center stage に表示中の pane (= agent)
- `offStageOrder: [String]`: 左 off-stage の表示順 (drag で並び替えた結果)
- `dismissedPaneIds: Set<String>`: hide 済 (任意 — 「もう見ない」できる)

→ Request という独立 entity は **作らない**。「ユーザーが出す要求」はそのまま該当 agent (pane) の terminal に投げる文字列なので、AgentSession.lastUserPrompt に既に記録されてる。

## 5. UX フロー

### 新しいタスクを出す (= 新 agent 起動)
1. 右下 "+ New Agent" FAB → modal で「project + 初期タスク文」入力
2. Submit → 該当 project に新 pane spawn + claude code 起動 + 初期タスク文を input
3. 中央 center stage に **にゅっと** 出現 (新 agent が即 center)

### 既存 agent への追加指示
- center stage 下部の input bar で打って Enter
- 内部的には pane の terminal にそのまま送信される (= 既存の入力経路)

### 完了 review
1. agent が `waiting` (user 入力待ち) or `completed` になる
   → off-stage card の右上に **✓ 強調表示** + pulse
2. ユーザーがそのカードをクリック
   → 該当 agent が center stage に hero animation で swap
3. ユーザーは summary / log / 触ったファイル等を確認
4. アクション:
   - **Approve / Done**: agent をそのまま放置 (= idle 化) or 閉じる
   - **追加指示**: input bar に書いて再開
   - **Dismiss / Hide**: stage から外す (= pane は生かしたまま off-stage から消す)

### 進捗の見え方 (off-stage)
- card 内: status indicator + project · pane 名 + 現在のタスク 1 行 summary
- terminal の raw output は見せない (= 見たければ center に上げる)
- Status の色 / アイコンで「動いてる / 待ってる / 完了 / idle」を区別

## 6. UI Layout 詳細案

### A. 全体構造

固定 column 分割ではなく **ZStack に floating cards** + **中央 hero area**:

```
ZStack {
  ForEach(offStageAgents) → AgentCard       // 左側に縦並び浮遊
  CenterStageCard(centerPaneId)             // 中央、大きく
  NewAgentButton                            // 右下 FAB
}
```

各 AgentCard は SwiftUI `matchedGeometryEffect(id: paneId, in: stageNamespace)` で hero animation 対象に。同じ id を持つ「off-stage 表現」と「center stage 表現」が swap されると SwiftUI が補間してアニメーションする。

### B. Off-stage agent cards

- 左端に縦並び (余白 10pt で浮遊感)
- size: ~200×80pt (= sidebar session row 寄り、terminal 縮小ではない)
- **内容は sidebar の SessionRow に近い**:
  - 上段: status indicator + project · pane 名 (≪Project name · 1≫)
  - 中段: ユーザーの直近依頼 (= AgentSession.lastUserPrompt の冒頭、line clip)
  - 下段: agent が何をしてるか (= AgentSession.message / lastAgentActivity)
- terminal の生 output は出さない (= "ざっくり何してる" レベル)
- ✓ 強調 (waiting / completed): 右上バッジ + accent border + 軽い pulse
- click → center に hero swap
- drag で並び替え

### B-2. Off-stage が溢れたら (= Stage Manager 風 stacking)

- 表示可能数 (e.g. 6 枚) を超えたら **下に向かって重ねる**:
  - 6 枚目の下に 7 枚目 / 8 枚目が後ろから 4-8pt ずらしで顔を出す
  - 後ろの card は opacity 0.6 / scale 0.95 で「奥行き」を表現
  - hover でめくれて顔を出す or click で前に来る
- 重ね順は新しい report 提出済 / waiting 優先 → idle が一番奥

### C. Center stage

- 中央に大きく (画面幅 60-70%、高さ 70-80%)
- rounded corners + subtle shadow + 背景 surface
- 構造:
  - 上部: agent header (project / pane / status indicator + close ボタン)
  - 中部: terminal (= XTermTerminalView を埋込、PaneHostRegistry の WebView 流用)
  - 下部: input bar (= terminal にそのまま流す textfield + Send 単発、Approve / Dismiss action)
- Off-stage から swap → **にゅっと拡大**
- 元 center は off-stage 末尾に **しゅっと縮小**

### D. New Agent FAB

- 右下隅に floating (`+` icon)
- click → **即座に新 pane spawn** (= modal なし):
  - 起動先 project = **現在 center stage に出してる agent の project** (= "current project" を継承)
  - 中央に **にゅっと** 出現 → そのまま center stage 化
  - terminal が直接表示 → ユーザーが直接打ち込んで初期タスクを与える
- 既存 center にあった agent は off-stage 末尾へ縮小退場
- center が空 (= 全部 dismiss 済) の時は default project (= sidebar 1 番目) に spawn

### E. アニメーション 仕様

- Card 間遷移: `matchedGeometryEffect` + `spring(response: 0.4, dampingFraction: 0.75)`
- 新 agent spawn: scale 0.85 → 1.0 + opacity 0 → 1
- Off-stage drag 並び替え: `interactiveSpring(response: 0.2)`
- Hover: `scale(1.02)` + slight shadow lift
- ✓ pulse: opacity 0.7 ↔ 1.0、2s 周期

物理感のある spring で macOS Stage Manager と同じテンポ感。

## 7. 既存 view との関係

- Project view / Tile view と並列の 3rd mode (ViewMode に `.stage` 追加)
- `PaneHostRegistry` を利用して既存 pane インスタンスを center stage / off-stage に embed
- 同じ shared state (CommandAreaState / NotificationStore) を使う
- 新 service `StageViewState` で center pane / off-stage 順序 / dismissed 一覧を管理 (永続化)
- Request / Report は **独立 entity 不要** (= AgentSession.lastUserPrompt + 最新 output で代替)

## 8. MVP スコープ (最小) と将来

### MVP (まず動かす)
- ViewMode に `.stage` 追加
- Stage view 骨組 (ZStack with floating cards)
- Off-stage cards = 全 pane を agent card として縮小表示
- Center stage = 選択 pane の terminal を大きく表示 + 下部 input bar
- hero animation で off-stage ↔ center swap
- "+ New Agent" FAB (= 新 pane spawn + 初期タスク input)
- ✓ 強調 (waiting / completed status の card)

### Phase 2
- Summary / Changes 表示 (= terminal log を解析して要約タブ)
- Dismiss / Hide 機能 (= off-stage から外す)
- Drag-to-rearrange off-stage 順序

### Phase 3
- Notification (waiting/completed になった時に macOS 通知)
- Cross-project agent group (= 同じ要求を複数 project に並列展開)

## 9. 確定事項 (議論済)

1. ✅ **Agent の単位**: 1 pane = 1 agent
2. ✅ **Request の扱い**: 独立 entity 不要、agent への input として吸収
3. ✅ **Terminal log の見せ方**: center stage で terminal そのまま表示
4. ✅ **新 agent 起動先 project**: 現在 center に出してる project を継承 (= current project)、空なら sidebar 1 番目
5. ✅ **Off-stage 溢れ**: Stage Manager 風 **stacking** (後ろにずらして重ねる、scroll しない)
6. ✅ **Sidebar**: 強制非表示 (Tile mode と同じ扱い)
7. ✅ **Off-stage card 中身**: sidebar の SessionRow 風 (status indicator + project · pane + ユーザー依頼 + 動作 summary)、terminal thumbnail ではない
8. ✅ **新 agent 起動 UI**: modal なし、即座に新 pane spawn → center stage に来る → terminal 直接タイプ

## 10. 次にやること

1. この doc を user とすり合わせ、論点 (9) を埋める
2. MVP スコープの確定
3. UI モックを 1 枚作る (e.g. SwiftUI で見た目だけ)
4. データモデル (Request / Report) 仕様を確定
5. Phase 1 実装着手
