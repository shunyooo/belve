import Foundation
import Combine

/// Tile view のフィルタ状態。AppConfig に永続化。
@MainActor
final class TileFilterState: ObservableObject {
	static let shared = TileFilterState()

	enum StatusFilter: String, Codable, CaseIterable, Identifiable {
		case all       // 全 pane
		case active    // running / runningSubagent / waiting (= 何かやってる or 待ってる)
		case idle      // 上記以外 (idle / sessionStart / completed / sessionEnd)

		var id: String { rawValue }

		var label: String {
			switch self {
			case .all: return "All"
			case .active: return "Active"
			case .idle: return "Idle"
			}
		}
	}

	enum SortOrder: String, Codable, CaseIterable, Identifiable {
		case project       // sidebar の project 順、各 project 内 pane 順
		case status        // active 系を先、idle 系を後
		case recent        // 最後に activity (= AgentSession.updatedAt) があった順
		case pinned        // pinned 先、残りは project 順

		var id: String { rawValue }
		var label: String {
			switch self {
			case .project: return "Project"
			case .status: return "Status"
			case .recent: return "Recent"
			case .pinned: return "Pinned"
			}
		}
		var icon: String {
			switch self {
			case .project: return "folder"
			case .status: return "circle.dotted"
			case .recent: return "clock"
			case .pinned: return "pin"
			}
		}
	}

	@Published var sortOrder: SortOrder = .project {
		didSet { if oldValue != sortOrder { save() } }
	}

	enum LayoutMode: String, Codable, CaseIterable, Identifiable {
		case grid       // 縦横の grid (LazyVGrid)
		case row        // 横並び 1 行、横スクロール、tile は full height

		var id: String { rawValue }
		var icon: String {
			switch self {
			case .grid: return "square.grid.2x2"
			case .row: return "rectangle.split.3x1"
			}
		}
	}

	@Published var layoutMode: LayoutMode = .grid {
		didSet { if oldValue != layoutMode { save() } }
	}

	@Published var statusFilter: StatusFilter = .all {
		didSet { if oldValue != statusFilter { save() } }
	}

	/// 表示対象 project (空なら全 project)。
	@Published var selectedProjectIds: Set<UUID> = [] {
		didSet { if oldValue != selectedProjectIds { save() } }
	}

	/// Pin 済 pane (filter 関係なく常に表示)。
	@Published var pinnedPaneIds: Set<String> = [] {
		didSet { if oldValue != pinnedPaneIds { save() } }
	}

	/// Tile 全体で単一の focus 対象 (project 横断)。永続化なし。
	/// project 別の activePaneId とは独立。tile cell の border 表示と Cmd+;'
	/// による pane cycle に使う。
	@Published var focusedPaneId: String? = nil

	/// Tile grid の列数 (1-8)。
	@Published var columnCount: Int = 3 {
		didSet {
			let clamped = min(max(1, columnCount), 8)
			if clamped != columnCount {
				columnCount = clamped
				return
			}
			if oldValue != columnCount { save() }
		}
	}

	/// Grid mode で 1 画面 (visible area) に縦に何 tile 入るか (1-8)。
	/// 実 cell 高さは visible height / rowsPerScreen で計算。
	@Published var rowsPerScreen: Int = 3 {
		didSet {
			let clamped = min(max(1, rowsPerScreen), 8)
			if clamped != rowsPerScreen {
				rowsPerScreen = clamped
				return
			}
			if oldValue != rowsPerScreen { save() }
		}
	}

	/// Tile header の高さ (pt)。0 = header 非表示。
	@Published var headerHeight: CGFloat = 18 {
		didSet {
			let clamped = min(max(0, headerHeight), 40)
			if clamped != headerHeight {
				headerHeight = clamped
				return
			}
			if oldValue != headerHeight { save() }
		}
	}

	private static var configURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("tile-filter.json")
	}

	private struct Persisted: Codable {
		var statusFilter: String?
		var selectedProjectIds: [String]?
		var pinnedPaneIds: [String]?
		var columnCount: Int?
		var layoutMode: String?
		var rowsPerScreen: Int?
		var headerHeight: CGFloat?
		var sortOrder: String?
	}

	private init() {
		load()
		// Pane が close された時に focused / pinned から自動で外す
		// (Cmd+W や close button 経由いずれの場合も confirm)。
		NotificationCenter.default.addObserver(
			forName: .belvePaneClosed, object: nil, queue: .main
		) { [weak self] notif in
			guard let self, let paneId = notif.userInfo?["paneId"] as? String else { return }
			if self.focusedPaneId == paneId { self.focusedPaneId = nil }
			if self.pinnedPaneIds.contains(paneId) { self.pinnedPaneIds.remove(paneId) }
		}
	}

	private func load() {
		guard let data = try? Data(contentsOf: Self.configURL),
		      let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
		if let raw = p.statusFilter, let f = StatusFilter(rawValue: raw) {
			statusFilter = f
		}
		if let ids = p.selectedProjectIds {
			selectedProjectIds = Set(ids.compactMap { UUID(uuidString: $0) })
		}
		if let ids = p.pinnedPaneIds {
			pinnedPaneIds = Set(ids)
		}
		if let n = p.columnCount {
			columnCount = min(max(1, n), 8)
		}
		if let raw = p.layoutMode, let m = LayoutMode(rawValue: raw) {
			layoutMode = m
		}
		if let n = p.rowsPerScreen {
			rowsPerScreen = min(max(1, n), 8)
		}
		if let h = p.headerHeight {
			headerHeight = min(max(0, h), 40)
		}
		if let raw = p.sortOrder, let s = SortOrder(rawValue: raw) {
			sortOrder = s
		}
	}

	private func save() {
		let p = Persisted(
			statusFilter: statusFilter.rawValue,
			selectedProjectIds: selectedProjectIds.map { $0.uuidString },
			pinnedPaneIds: Array(pinnedPaneIds),
			columnCount: columnCount,
			layoutMode: layoutMode.rawValue,
			rowsPerScreen: rowsPerScreen,
			headerHeight: headerHeight,
			sortOrder: sortOrder.rawValue
		)
		if let data = try? JSONEncoder().encode(p) {
			try? data.write(to: Self.configURL)
		}
	}

	/// 現在の sortOrder に従って任意の pane 配列を並び替える generic helper。
	/// TileView (表示順) と MainWindow.cycleTileFocus (Cmd+;' 順序) で同じロジックを共有。
	/// 同 priority 内の安定性は projectOrder → paneIndex の自然順。
	func sort<T>(
		_ items: [T],
		paneId: @escaping (T) -> String,
		projectOrder: @escaping (T) -> Int,
		paneIndex: @escaping (T) -> Int,
		status: @escaping (T) -> AgentStatus,
		lastActivity: @escaping (T) -> Date?
	) -> [T] {
		let natural: (T, T) -> Bool = { lhs, rhs in
			let lo = projectOrder(lhs); let ro = projectOrder(rhs)
			if lo != ro { return lo < ro }
			return paneIndex(lhs) < paneIndex(rhs)
		}
		switch sortOrder {
		case .project:
			return items
		case .status:
			return items.sorted { lhs, rhs in
				let lp = Self.statusPriority(status(lhs))
				let rp = Self.statusPriority(status(rhs))
				if lp != rp { return lp < rp }
				return natural(lhs, rhs)
			}
		case .recent:
			return items.sorted { lhs, rhs in
				let lt = lastActivity(lhs) ?? .distantPast
				let rt = lastActivity(rhs) ?? .distantPast
				if lt != rt { return lt > rt }
				return natural(lhs, rhs)
			}
		case .pinned:
			return items.sorted { lhs, rhs in
				let lp = pinnedPaneIds.contains(paneId(lhs))
				let rp = pinnedPaneIds.contains(paneId(rhs))
				if lp != rp { return lp }
				return natural(lhs, rhs)
			}
		}
	}

	static func statusPriority(_ s: AgentStatus) -> Int {
		switch s {
		case .running: return 0
		case .runningSubagent: return 1
		case .waiting: return 2
		case .completed, .sessionEnd: return 3
		case .sessionStart: return 4
		case .idle: return 5
		}
	}

	/// status と pin を考慮した表示判定。Pin 済なら常に通す。
	func shouldShow(paneId: String, projectId: UUID, status: AgentStatus) -> Bool {
		if pinnedPaneIds.contains(paneId) { return true }
		if !selectedProjectIds.isEmpty && !selectedProjectIds.contains(projectId) { return false }
		switch statusFilter {
		case .all:
			return true
		case .active:
			// running 系 + waiting + 完了直後 (done) + 起動中 (sessionStart) を含める。
			// 完全な dormant (.idle) のみ除外。
			return status != .idle
		case .idle:
			return status == .idle
		}
	}
}
