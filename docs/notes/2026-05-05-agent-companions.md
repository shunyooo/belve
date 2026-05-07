# Agent Companions — セッションごとの常駐エージェント表示

## 背景

各セッションで動いてるエージェント (= claude code) の活動を「常駐キャラクター」として画面に浮かべる。Office アシスタント (イルカ / Clippy) のような小さい floating panel が複数浮かび、各々が今やってることを speech bubble で喋る。

現状: sidebar の session row でエージェント状態は見れるが、(1) 常時 sidebar 開いてる必要がある、(2) 通知より弱い「環境的気付き」が無い、という課題。

## 設計

### Window 構造

**独立した floating NSPanel (= companion 1 つ = window 1 つ)** を採用。

- macOS 全画面に対して floating (= 他アプリ前面に居続ける)
- 非アクティブ化 (= companion click でも main app は active のまま、frontmost 奪わない)
- 透過背景 + 影
- 各 companion が個別に drag 可能、位置は per-session 記憶

### Companion の構成

```
┌─────────────┐
│  [sprite]   │  ← StatusIndicator 由来の animated sprite
│  ▔▔▔▔▔     │
│ project ›   │  ← 文脈 (project breadcrumb)
│ "Reading    │  ← 現 activity を speech bubble で
│  config.ts" │
└─────────────┘
```

- アバター: 既存 StatusIndicator の sprite (parrot / subagent) を流用、後で variants 追加
- 1 行目: project / view 名 (小さく)
- 2 行目: 現 tool / status text を speech bubble 風に表示 (例: "Reading: file.swift", "Waiting for input")
- 状態色: running=accent, waiting=yellow, completed=green, etc.

### ライフサイクル

- AgentSession が **アクティブ (= running / waiting / sessionStart)** に入ると companion 自動生成
- AgentSession が **completed / sessionEnd** に入ると companion 自動 dismiss (= 数秒の completion アニメーション後消える)
- ユーザー dismiss = 強制非表示 (= session は生きてるが panel だけ閉じる)

### 操作

- **Click**: 該当 project / view に jump (= sidebar session row click と同じ動線)
- **Drag**: 自由配置、位置は per-session で永続化
- **Right-click**: context menu
  - "Change avatar" → sprite picker
  - "Dismiss" → panel 閉じる (session は生存)
  - "Mute notifications" → 通知抑制

### アバター

- 初版: 既存 sprite (= parrot / subagent) を random で割当
- session 作成時に決定、user が右クリックで変更可能
- 設定は per-pane (= AgentSession.paneId) で永続化
- 後で sprite variants を追加可能な構造 (= sprites/{name}/frames/*.png)

### sidebar との関係

両方残す (= 並列存在)。
- sidebar = 全 session の overview
- companion = 個別 session の常駐表示
- どちらも click で同じ view jump 動線

## 実装フェーズ

### Phase 1: MVP (= 基本動作)
- `AgentCompanionManager` (= per-session companion lifecycle 管理)
- `AgentCompanionPanel` (= NSPanel + SwiftUI hosting)
- `AgentCompanionView` (= sprite + speech bubble の SwiftUI view)
- 自動生成 (session active) + 自動 dismiss (session 終了)
- デフォルト配置: 画面右上に stack (= 重ならないよう offset)
- Click → view jump

### Phase 2: 操作
- Drag で自由配置、位置を per-session 永続化
- Right-click context menu (Change avatar / Dismiss / Mute)
- Mute 状態の永続化

### Phase 3: アバター強化
- Avatar picker UI (= sprite 一覧から選ぶ modal)
- Sprite variants 追加 (cat / robot / ghost 等)
- ランダム pick の重み付け (= 最近使ったやつ避ける)

### Phase 4: ポリッシュ
- 入退場アニメーション
- waiting 強調 (= 揺れる / 光る)
- アバター同士が近づくと「お互い見つめる」みたいな細かい動き (= 余裕あれば)

## 未決事項

1. **画面跨ぎ**: 複数モニターで companion はどう振る舞う? (= 配置記憶は monitor 単位 vs 絶対座標)
2. **performance**: 10+ companions 同時表示時の FPS / RAM 影響 (= sprite animation × N)
3. **常駐 process**: companion panel は Belve.app の lifecycle に従う (= app quit で全消滅) で OK?
4. **キーボードフォーカス**: companion click で main app が active 化しない場合、keyboard focus どこに行く?

## 関連

- 既存 StatusIndicator (= sprite system) を流用
- NotificationStore.sessions を監視して lifecycle 駆動
- ProjectViewStore で view 名を解決
