# View 単位の主動線への再設計

## 背景

現状は **1 project = 1 view** で、view 内に N 個の terminal pane が並ぶ構成。同時並行 session が増えると 1 view 内が手狭になり、ペインが小さくなって作業しづらい。Tile mode で凌いでいるが、根本は「pane 単位ではなく、もっと作業文脈に合った単位で view を切り替えたい」という需要。

(Stage mode は同 2026-05-04 時点で廃止済み。本 design はそのリプレースを兼ねる。)

ユーザー観察:
- Project はサクサク切り替えるもの
- 1 つの作業文脈 (= claude 1 session、1 タスク) は 1 画面占有してほしい
- でも作業中に「ちょっと別 cmd 走らせたい」用の sub terminal は欲しい

## 用語

新概念:
- **View** = Belve の UI 主単位。1 view = 1 main terminal + 0..N temp terminals + editor 状態
  - "session" は belve-persist / claude conversation と衝突するので採用せず
  - "task" は意味が重い (TODO 等と被る) ので採用せず
- **Project** ⊃ **View** ⊃ (main pane + temp panes + editor state)

既存概念 rename:
| 現状 | 新 |
|---|---|
| Project View (mode) | Project mode |
| Tile View (mode) | Tile mode |
| Stage View (mode) | Stage mode |

→ 「View」と「View mode」が混ざらないよう、mode 系は単に "mode" と呼ぶ。コードの型名 (`TileView`, `StageView`) はそのままで UI 文言のみ修正。

## 階層

```
Project (clay-api-flamel)
├── View "main"
│   ├── Main pane (= 1 belve-persist session、claude が走る)
│   ├── Temp pane (任意、user split で生やす)
│   └── Editor state (open file / file tree state)
├── View "db-migration"
│   └── Main pane + ...
└── View "feature-xyz"
    └── Main pane + ...
```

- **Main pane**: View 作成と同時に生成、削除不可。View の主動作 (claude / agent / メイン作業) を担う
- **Temp pane**: View 内で user が split して足す ad-hoc shell。閉じれる。view 切替で状態保持
- **Editor**: 今と同じく view ごとに「最後に開いてたファイル / file tree 開閉」状態を持つ

## Sidebar UX

```
▼ clay-api-flamel  🦜 1/3            ← project: 配下 view 集約 status + count
  🦜 main         "Working on auth"   ← view row、main pane status を表示
  🤔 db-mig       "Waiting"
  ◯  feature-xyz
  + New View
▶ kiwami           ◯ 0/3              ← collapsed でも親に集約 status
```

- Project row = view 集約 (running > waiting > idle > completed の順で最重要を表示) + `running数 / 全数` バッジ
- View row = main pane status (sprite indicator + last activity text)
- `+ New View`: project row 下の inline ボタン or Cmd+T (in project)

## View 作成 / 削除動線

**作成**:
1. `+ New View` (sidebar) または Cmd+T
2. 新 row 追加 → inline rename にフォーカス (空 Enter で auto 命名)
3. View 切替 → 空 editor + 1 fresh main terminal

**削除**:
- View row 右クリック → "Close View"
- Confirm → main pane の belve-persist session kill + temp panes も全 kill
- Project は view 0 でも残る

## 切替動線

| 操作 | 振る舞い |
|---|---|
| Sidebar click view | その view に瞬時 swap、terminal/editor 状態保持 |
| Cmd+] / Cmd+[ | 同 project 内の next / prev view |
| Cmd+Shift+] / Cmd+Shift+[ | 別 project (各 project の最後アクティブ view へ) |
| Cmd+1..9 | top 9 view に直接 jump (sidebar order) |

## View 内 UI

- Main pane: 上 or 中央配置、status sprite を枠角に表示
- Temp panes: split divider で分割、右クリック → close
- Editor: 右側 (今と同じ split / fraction)
- TopBar: `clay-api-flamel › main` (project breadcrumb + view 名) + 状態テキスト

## Status 集約 rule

- **Temp pane の status は view 集約に bubble up しない**
  - 理由: temp は ad-hoc shell (curl, ls 等) で長居用途じゃない。bubble up すると "session 全体 running" の意味がぼやける
  - View status = main pane status と等価
- View 内では temp pane も独自 indicator を出す (= 自分の枠角に小さく)

## Mode (= 旧 view modes) との関係

| Mode | 表示単位 | 振る舞い |
|---|---|---|
| Project mode (default) | 1 project の選択 view | 上記の view-as-primary そのもの |
| Tile mode | 全 view を gallery 表示 | 1 cell = 1 view (= main pane)。temp pane は表示しない |

- Tile は「全 panes 横断」→「全 views 横断」に変更
- Cmd+; (next running)、Cmd+Shift+; (next waiting) も view 単位で動く

## 移行: 既存 project が持つ N panes

既存 panes は "view" 単位に分割する必要あり。以下から選択:

- **A**: 各 pane を 1 view に昇格 (= N views になる、最も素直)
- **B**: 1 pane だけ main view、残りは「Migrated」default view の temp panes
- **C**: 起動時に Tile mode で表示 → user が手動で振り分け

→ 推奨 **A**。auto migration の loss が一番少ない。Auto 命名は pane index ベース ("View 1", "View 2"...) で、user が rename 可能。

## モデル変更の影響範囲

**新規**:
- `View` model (id, projectId, name, mainPaneId, tempPaneIds, editorState)
- `ViewStore` (project ごとに views 配列を管理、persist)

**修正**:
- `ProjectListView`: project row の下に view rows を expand 可能に
- `MainWindow.projectWorkspace`: per-view layout (= 現在の per-project の代わり)
- `WorkspaceLayoutState`: view 単位に分解 (editor / file tree state は view ごと)
- `CommandAreaState` / `stateManager`: pane 集合を view scope に
- `TileView` / `StageView`: pane iterate → view iterate に
- ショートカット: project 切替 → view 切替に再マッピング (Cmd+1..9, Cmd+] / [)
- `ProjectStore`: project の `panes` → `views` フィールドに置換、persist 形式更新

**削除予定なし** (= 内部 belve-persist session の概念は不変)

## 確定事項

1. **Temp pane の placement** → **Split** (= 今の pane と同じ縦横分割)
   - 既存 mental model 流用、claude main + `curl` 監視のような並行作業に自然
   - Tab / floating overlay は不採用 (= 実装 / UX コスト割に合わず)
2. **Project row click の挙動** → **最後アクティブだった view を開く + sidebar 自動展開**
   - 99% の用途 (= 「さっきの作業に戻る」) が 1 click 完結
   - Overview 画面は不要 (= sidebar が overview の役割を兼ねる)
3. **View ↔ git branch 紐付け** → **初版なし、純 UX 単位**
   - Auto checkout の race / 未 commit の扱いを回避
   - 必要になれば後付け (= optional flag) 可能、初版で背負うほどの確信なし
4. **Persist schema migration** → **bump version + 1 回限りの auto migration、旧 file は `.bak` 退避**
   - 既存 `workspace-layout.json` を読み、各 project の state を view "main" にマップ
   - 旧 file は `workspace-layout.json.bak` にリネームして safety net 確保
   - 並走 (= file 2 本) は採用せず (= 状態の真偽が分散して悪化する)
5. **Process 負荷 (belve-persist 常駐数)** → **refactor 自体での増加なし、運用での増加は許容**
   - 移行は「各 pane → 1 view」の 1:1 マッピングなので process 数不変
   - View が作りやすくなる UX 改善の結果、user が増やす方向に動く可能性あり (= 1 project 5 view 級)
   - belve-persist 自体は idle 5MB / process と軽量なので OS レベル懸念は低い
   - 必要になったら soft cap (= project あたり N view 超で warn) を後付け、初版では実装しない

## 実装フェーズ案

1. **Phase 0**: 設計確定 (= この memo)
2. **Phase 1**: Model 層に `View` 導入、`Project.views: [View]` に置換、persist schema migration
3. **Phase 2**: Sidebar に view row を表示 (展開 / 折りたたみ)、view 切替で main view 表示
4. **Phase 3**: View 作成 / 削除 / rename UI
5. **Phase 4**: View 内 split (temp pane) UI
6. **Phase 5**: Status 集約 (project row badge)、shortcut 再マッピング
7. **Phase 6**: Tile / Stage mode を view iterate に書き換え
8. **Phase 7**: 既存 project の auto migration (= 各 pane → 1 view 昇格)
9. **Phase 8**: Documentation 更新 (architecture.md / development-guide.md)
