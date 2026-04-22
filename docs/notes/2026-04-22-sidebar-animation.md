# Project sidebar の選択切替 animation 問題

作成日: 2026-04-22
ステータス: 一旦 animation 撤去で着地。再挑戦余地あり。

## 症状

Project サイドバーで別 project をクリックして切り替えた時、選択 highlight
の移動にワンテンポ (~0.5s 体感) 遅れがある。一方、メインエリア (terminal /
PreviewArea) は keep-alive 構造のため opacity 切替で即時に新 project の
内容が表示される。

→ **メインエリアは即時 / サイドバーは遅延** という非同期感がユーザー体感を
悪化させていた。

## 試したこと

| アプローチ | 結果 |
|---|---|
| `.animation(.timingCurve(...), value: selectedProject)` (元) | 0.18s。重い 12 row + matchedGeometryEffect で frame drop あり |
| `matchedGeometryEffect` を撤去 → fade のみ | 滑らかさは出たが「ワンテンポ遅れ」感は残る |
| `.animation` の duration を 0.08s に短縮 | まだ遅れて感じる |
| ScrollView 全体ではなく ProjectRow の selection 背景にのみ局所 animation | 体感変わらず |
| 新選択 instant + 旧選択 fade-out (0.18s) の非対称 | 改善効果薄い |
| **animation 完全撤去 (採用)** | メインエリアと同タイミングで切替 |

## 学んだこと

- SwiftUI の `.animation(value:)` を ScrollView 配下の親に当てると、配下の
  全 row の差分計算が implicit animation 対象になり、12+ row だと frame
  drop しやすい
- `matchedGeometryEffect` は要素位置を毎フレーム再計算するため、行数が
  多い list では負荷が大きい
- `ProjectRow` が `@EnvironmentObject projectStore` を観察してると、
  git 等の無関係な @Published 変更で全 row が再 render される。closure
  経由の値渡しに切り替えると row 自体の re-render 頻度は減らせる (これは
  別件として `loadingStatusFor` で実装済み)
- 選択切替のような **クリック直後の即時フィードバックが期待される操作**
  では、人間の知覚上「最初の数 frame」の遅延が体感に強く影響する。アニメ
  ーションを入れるなら 1-2 frame (16-32ms) 程度に収めるか、別軸で smooth
  さを演出する必要がある

## 結論 (2026-04-22 時点)

**Sidebar の選択 highlight は animation なしで即時切替**。

メインエリアのキープアライブ + opacity 切替が完全即時なので、サイドバー
だけ animate すると同期感が崩れる。両方とも instant の方が UX 整合性が
高い。

## 再挑戦するなら

- main area 側にも同タイミングの fade animation を入れて、両方を 50-80ms
  くらいで統一する
- ProjectRow を `EquatableView` で wrap して、不要な再 render を厳密に
  抑制する
- LazyVStack に変更して off-screen row のレイアウト計算を省く
- もしくは「選択枠線が指している場所」を ProjectListView 直下に絶対配置
  された 1 個の `RoundedRectangle` として描画し、その position だけ
  animate (= 各 row は再 render しなくて済む)

## 関連ファイル

- `Sources/Belve/Views/Sidebar/ProjectListView.swift`
  - `var body` の selectedProject に対する `.animation` (撤去済)
  - `ProjectRow.body` の background ZStack
- `Sources/Belve/Views/MainWindow.swift`
  - `projectWorkspace` の `.opacity(isSelected ? 1 : 0)` (keep-alive 切替)
- `Sources/Belve/Services/ProjectStore.swift`
  - `func select(_ project: Project?)` (clicker → 選択伝播)
