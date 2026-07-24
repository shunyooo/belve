# Cockpit リプレイス 引き継ぎ（2026-07-25）

**対象**: `feat/cockpit` ブランチ。「Belve をエージェント司令塔へ」の背骨リプレイス。
**状態**: 背骨は完了・コード検証済み（build/test/レビュー）。**実機（実VM）検証は未実施**。
**契約/設計**: `docs/notes/2026-07-23-unified-agent-session.md`（§1–7 が背骨、**§8 が最新の方向：workspace 主単位化＋session 昇格ゲート**）。

## 何が完了したか（コミット）

新しい順。**`1e8af87` までは origin に push 済み。`9478a1d`〜`a878946` の5件は未 push**。

| commit | 内容 | push |
|---|---|---|
| `a878946c299` | discovery を **agent 検出ゲート化**（bare shell/node は session にしない、claude/codex 検出時のみ） | 未 |
| `983c1597728` | origin 昇格バグ修正（discovered→launched）＋ dead code 削除 | 未 |
| `f176bf8d6c9` | DevContainer 経路削除（Go: router 簡素化/setup/master/main、belve-setup）＋ persist 再ビルド | 未 |
| `18a90a59014` | DevContainer 削除（Swift）＋ serialize-restore 撤去 | 未 |
| `9478a1da8ce` | tmux セッション discovery（origin=.discovered） | 未 |
| `1e8af8727ad` | プレビュー右列 変更/ツリー トグル＋ChangedFilesStore | 済 |
| `95d10d6ce3e` | **識別子一本化**（pane/ProjectView/session→単一 AgentSession、SessionKey=tmux名、状態所有集約、NotificationStore 縮退、consumer 全移行、Cockpit フラット化） | 済 |

→ **まず `git push`**（未 push 5件）。※ CI/リモート環境の資格情報が要るためツール側では push 不可、手元ターミナルで実行。

## アーキテクチャ（現状の到達点）

- **AgentSession**（`Models/AgentSession.swift`）: 一級・永続実体。`id = SessionKey = tmux セッション名`。state(working/blocked/done/idle…)、origin(.launched/.discovered)。
- **AgentSessionStore**（`Services/AgentSessionStore.swift`）: 状態の唯一の所有者。triage 集約、pane↔SessionKey binding、publish coalescing、`sessions.json` 永続化、`mergeDiscovered`（.launched は不可侵）。
- **NotificationStore**: 通知専用に縮退（session 状態は持たない）。OSC は端で両ストアへ dispatch。
- **SessionDiscoveryService**: `tmux list-sessions/panes` を解析。`agentCommands = {claude, codex}` を検出した session のみ surface。
- **OSC**: hook が `BELVE3:<paneId>:<tmuxSession>:<sessionId>:<status>:<message>` を送出（tmux `#S` を権威に）。
- **container/VT snapshot 撤去済み**、**mux/router/tunnel/broker/deployBundle/bounded-replay は温存**（router は宛先解決のみ簡素化し常にローカル broker `127.0.0.1:19223/19225`）。

## 実機で検証すべきこと（サンドボックスでは不可、要手動）

ビルド済み `.app` はローカルコード反映済み。`pkill -f 'MacOS/Belve$'; open Belve.app` で起動（**起動しクラッシュしないことは確認済み**、ただしウィンドウ動作は未確認）。

1. **リモート SSH プロジェクト接続でターミナルが開くか** ← 簡素化 `router.go`（常にローカル broker）の最重要検証。`mux→router→127.0.0.1:19223→session-bootstrap.sh→tmux`。
2. claude 起動 → サイドバーに working セッション＋コンパニオン。
3. Belve 外の `ssh→tmux→claude`（or codex）を discovery が拾うか。**素の shell だけの tmux は session として出ないこと**。
4. `agentCommands` が実環境の `pane_current_command` と一致するか（claude/codex が `node`/`python` wrapper で出るなら `SessionDiscoveryService.agentCommands` に追記、または pane pid argv 検査を実装）。
5. プレビュー 変更/ツリー トグル、変更一覧の選択→エディタ連動。
6. デタッチ→再アタッチで bounded replay により画面復元されるか（serialize-restore 撤去済み）。

### スクショ手順（参考・CLAUDE.md）
```bash
osascript -e 'tell app "System Events" to tell process "Belve" to set frontmost to true'
WINID=$(swift -e 'import CoreGraphics; let l=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []; for w in l { if let o=w[kCGWindowOwnerName as String] as? String, o=="Belve", let i=w[kCGWindowNumber as String] as? Int { print(i); break } }')
screencapture -l$WINID -x /tmp/belve-ui.png
```

## 実機動作確認で発見・修正した重大バグ（2026-07-25 追記）

サンドボックスで build/test/`.app` 起動確認中に、**アイドル時 ~20Hz の再描画ループ + 永続ファイル無限肥大**を発見し修正した。

- **症状**: 無操作でも `FileTreeView.body` が全 project で ~20Hz 再評価され続け、毎回 `CommandAreaStateManager.save()` が肥大 dict（~9500件/1.8MB）をメインスレッドで全 JSON エンコード（`sample` で主スレッド時間の 2014/2304 が `save()`）。CLAUDE.md が警告する入力ラグ型のバグ。
- **根本原因**: `MainWindow.swift` の `activeCommandState: commandAreaState(for: projectStore.selectedProject?.id ?? UUID())`。project 未選択時に `?? UUID()` が body 評価のたび fresh UUID を捏造 → `viewStore.activeView(for:)` → `ensureMainView` が `@Published viewsByProject` を body 中に mutate → 再レンダー誘発 → 新 UUID …の自己駆動ループ。副作用で pane-layouts.json / views.json / workspace-layout.json にファントム view が毎レンダー蓄積。CLAUDE.md 禁止の「優しい fallback」（未選択を偽 id で握りつぶす）そのもの。
- **修正**: 未選択時は id を捏造せず、`CommandAreaStateManager` に登録しない=永続化されない安定プレースホルダ `noSelectionCommandState`（@StateObject）を渡す。
- **検証**: 修正後 `.app` を起動 → `[drop] overlay` ログ 0件（ループ消滅）、pane-layouts entry 増加ほぼ停止、テスト 29/29 green。
- **蓄積ゴミの掃除**: 実 project 15件に対応するキーだけ残して pane-layouts.json（1.8MB→4KB）/ views.json / workspace-layout.json / open-files.json を pruning（各 `*.2026-07-25-precleanup.bak` バックアップ保存済み。全15 project のレイアウト欠損ゼロを確認）。

### 未解決の軽微な残渣（要 follow-up）

- **create-on-read アンチパターン**: `ProjectViewStore.activeView(for:)` と `CommandAreaStateManager.state(for:)` は**未知 id でも新規生成＋永続化**する。上記の暴走ループは消えたが、起動ごとに一過性のプレースホルダ project（`ProjectStore.loadProjects` の `Project(name:"Project 1")` 系、fresh UUID）を参照する経路が残っており、**起動ごとに phantom が +1** 蓄積する（file は ~4KB 維持で暴走はしない）。根本対処は「id が projectStore 未登録なら resurrect しない」= create-on-read を lookup-only にする方向で、§8.1 の workspace/SessionKey 紐付けと合わせて設計するのが素直。

## 残タスク（未実装）

- **§8.1 workspace 主単位化（次の大きな塊）**: `Project ⊃ Workspace(1..N) ⊃ {main agent pane + 補助ペイン + editor}`。多 workspace 対応、`ProjectView.id==projectId` スタブ解消、レイアウト永続化（pane-layouts.json / workspace-layout.json）の SessionKey 紐付け。方向は §8 に確定済み。着手前に「(x) 補助ペインは別 tmux だがサイドバー非表示 / (y) 1 workspace=1 tmux で補助は window/split」の設計判断が必要。
- **UI ポリッシュ**: NotificationStore→NotificationService 改名、BottomBar active 数から sessionStart 除外、ProjectRow に rollup 状態ドット描画、dismiss 済み→blocked 再浮上、stale な DevContainer コメント一掃、`terminal-bundle.js` の未使用 terminalSerialize/Restore 除去（`scripts/terminal-entry.js` 再生成）。
- **7b の VM 検証項目**: 上記「実機で検証」1・6。

## 進め方（このセッションで採った方式）

オーケストレータ＋検証者モデル: 各ユニットは実装をサブエージェントに発注 → 差分/ビルド/テストを本人が検証 → Plan/Rules レビュー（サブエージェント）→ 突き合わせ → commit。契約ノートを単一の真実源として drift を抑制。ユニットごとに small・build green を維持。

## 環境メモ（引き継ぎ先が別環境の場合）

このアシスタント実行環境はサンドボックスで、**キーチェーン/ネットワーク/GUI 前面化に非アクセス**。そのため push・実VM接続・スクショ（前面化）は手元ターミナルが必要。ビルド（swift/go）・テスト・ファイル操作は可能。
