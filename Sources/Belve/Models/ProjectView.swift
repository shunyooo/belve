import Foundation

/// Belve UI の主単位。1 project が複数の view を持ち、ユーザーは view を切り替えて
/// 作業文脈を行き来する (= 1 view = 1 main pane + 0..N temp panes + editor 状態)。
///
/// SwiftUI.View との衝突を避けるため Swift 上の型名は `ProjectView`。UI 文言上は
/// 単に "View" と表記する (see docs/notes/2026-05-04-view-as-primary-unit.md)。
///
/// Phase 1 では「1 project = 1 view "main"」固定で運用する (= 既存挙動と等価)。
/// 各種 per-project state (PaneNode tree, editor 状態, file tree 状態) のキーは
/// 過渡期に view.id == project.id とすることで既存ファイルをそのまま使えるように
/// している。Phase 2 で sidebar に view 列挙 + 切替 UI を導入する時点で多 view 化。
struct ProjectView: Identifiable, Codable, Hashable {
	let id: UUID
	let projectId: UUID
	var name: String

	init(id: UUID, projectId: UUID, name: String) {
		self.id = id
		self.projectId = projectId
		self.name = name
	}

	/// Phase 1 用: project と 1:1 の "main" view を生成する。view.id は projectId と
	/// 同じ UUID にして、既存の per-project state ファイル (= projectId キー) を
	/// view.id キーとしてそのまま流用できるようにする。
	static func main(for projectId: UUID) -> ProjectView {
		ProjectView(id: projectId, projectId: projectId, name: "main")
	}
}
