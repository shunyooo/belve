import Foundation
import Combine

/// Stage view (= Stage Manager 風) の状態管理。
///
/// 1 card = 1 agent = 1 pane の前提で、center / off-stage の配置と並び順を持つ。
/// セッションスコープの状態 (永続化なし) — 起動毎にデフォルト (= sidebar 順) で並び直す。
final class StageViewState: ObservableObject {
	static let shared = StageViewState()

	/// Center stage (中央) に配置中の pane id。nil なら center 空 (= 全 dismiss 済 or pane 0)。
	@Published var centerPaneId: String?

	/// Off-stage の表示順 (= 左側に並ぶ card 順)。drag で並び替えた結果を反映。
	@Published var offStageOrder: [String] = []

	/// 「もう見ない」マーク済の pane 一覧。stage には出さない (= pane 自体は生きてる)。
	@Published var dismissedPaneIds: Set<String> = []

	private init() {
		// pane が close されたら state からも掃除。
		NotificationCenter.default.addObserver(
			forName: .belvePaneClosed, object: nil, queue: .main
		) { [weak self] notif in
			guard let self, let paneId = notif.userInfo?["paneId"] as? String else { return }
			if self.centerPaneId == paneId { self.centerPaneId = nil }
			self.offStageOrder.removeAll { $0 == paneId }
			self.dismissedPaneIds.remove(paneId)
		}
	}

	/// 指定 pane を center stage に。元 center は off-stage 末尾へ退場。
	func promoteToCenter(_ paneId: String) {
		if let prev = centerPaneId, prev != paneId {
			offStageOrder.removeAll { $0 == prev }
			offStageOrder.append(prev)
		}
		offStageOrder.removeAll { $0 == paneId }
		centerPaneId = paneId
	}

	/// Stage から外す (= pane は close せず、stage 上だけ非表示)。
	func dismiss(_ paneId: String) {
		dismissedPaneIds.insert(paneId)
		if centerPaneId == paneId { centerPaneId = nil }
		offStageOrder.removeAll { $0 == paneId }
	}
}
