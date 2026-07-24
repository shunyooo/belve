import SwiftUI

/// 全 project の terminal pane を grid で並べた監視ビュー (cross-project gallery)。
///
/// 各 pane の WKWebView は PaneHostRegistry 経由で project view と共有される。
/// 同時に同じ WebView を 2 か所に attach できないため、project view と tile view は
/// MainWindow で if-else で排他的に表示される。view mode 切替時、SwiftUI の
/// makeNSView が registry から既存 WebView を返し、新しい親 NSView に reparent される。
struct TileView: View {
	@EnvironmentObject var projectStore: ProjectStore
	@EnvironmentObject var agentSessionStore: AgentSessionStore
	@ObservedObject private var filterState = TileFilterState.shared
	@ObservedObject private var registry = PaneHostRegistry.shared
	/// 各 project の pane tree の source of truth。MainWindow から注入。
	/// registry が未 populated でも (= 起動直後 tile mode 等) ここから pane 一覧を
	/// 直接取れるので、TileCell が初回 mount で registry に register する流れになる。
	let stateManager: CommandAreaStateManager

	private var headerHeight: CGFloat { filterState.headerHeight }

	private var columns: [GridItem] {
		Array(repeating: GridItem(.flexible(), spacing: 14), count: filterState.columnCount)
	}

	var body: some View {
		VStack(spacing: 0) {
			TileFilterBar(
				projectsForGroup: groupedProjects
			)
			Theme.borderSubtle.frame(height: 1)
			content
			let hidden = hiddenPanes
			if !hidden.isEmpty {
				Theme.borderSubtle.frame(height: 1)
				hiddenTray(hidden)
			}
		}
		.background(Theme.bg)
	}

	/// 非表示 pane のチップトレイ (画面下部)。チップクリックで復活。
	private func hiddenTray(_ panes: [PaneCellInfo]) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 6) {
				HStack(spacing: 4) {
					Image(systemName: "eye.slash")
						.font(.system(size: 9))
					Text("Hidden")
						.font(.system(size: 10, weight: .semibold))
				}
				.foregroundStyle(Theme.textTertiary)

				ForEach(panes, id: \.cellKey) { entry in
					Button(action: { filterState.unhidePane(entry.paneId) }) {
						HStack(spacing: 4) {
							StatusIndicator(status: entry.status, sizeOverride: 8)
							Text("\(entry.project.name) #\(entry.paneIndex + 1)")
								.font(.system(size: 10))
								.foregroundStyle(Theme.textSecondary)
								.lineLimit(1)
							Image(systemName: "arrow.up.left.square")
								.font(.system(size: 8))
								.foregroundStyle(Theme.textTertiary)
						}
						.padding(.horizontal, 8)
						.padding(.vertical, 3)
						.background(
							RoundedRectangle(cornerRadius: 4)
								.fill(Theme.surface)
						)
						.overlay(
							RoundedRectangle(cornerRadius: 4)
								.stroke(Theme.borderSubtle, lineWidth: 1)
						)
					}
					.buttonStyle(.plain)
					.help("Click to restore this pane")
				}
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 6)
		}
		.background(Theme.surface.opacity(0.5))
	}

	/// 非表示中の pane 一覧 (トレイ表示用)。visiblePanes と同じ走査で
	/// hiddenPaneIds に入ってるものだけ集める。
	private var hiddenPanes: [PaneCellInfo] {
		var result: [PaneCellInfo] = []
		for (projectIdx, project) in projectStore.projects.enumerated() {
			let state = stateManager.state(for: ProjectViewStore.shared.activeView(for: project.id).id)
			let status = agentSessionStore.rollupStatus(forProject: project.id) ?? .idle
			for (paneIdString, paneIndex) in collectLeafPanes(from: state.root) {
				guard filterState.hiddenPaneIds.contains(paneIdString) else { continue }
				result.append(PaneCellInfo(
					project: project,
					paneId: paneIdString,
					paneIndex: paneIndex,
					status: status,
					projectOrder: projectIdx
				))
			}
		}
		return result
	}

	@ViewBuilder
	private var content: some View {
		let panes = visiblePanes
		if panes.isEmpty {
			VStack(spacing: 12) {
				Spacer()
				Image(systemName: "square.dashed")
					.font(.system(size: 36, weight: .light))
					.foregroundStyle(Theme.textTertiary)
				Text("No panes match the current filter")
					.font(.system(size: 13))
					.foregroundStyle(Theme.textTertiary)
				Text("Try changing the status filter or selecting more projects.")
					.font(.system(size: 11))
					.foregroundStyle(Theme.textTertiary.opacity(0.7))
				Spacer()
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else if filterState.layoutMode == .row {
			horizontalRow(panes: panes)
		} else {
			gridLayout(panes: panes)
		}
	}

	/// 1 画面あたり rowsPerScreen 行になるように各 cell 高さを計算。
	/// ScrollView の visible 領域 (= GeometryReader の geo.size.height) を分割。
	/// 行が rowsPerScreen を超えたら下にスクロール。最低 80pt 保証。
	/// columnCount / rowsPerScreen は **max** 扱い: 実際の pane 数が少なければ
	/// それに合わせて少ない列・行に圧縮 (= 空き space を作らない)。
	private func gridLayout(panes: [PaneCellInfo]) -> some View {
		GeometryReader { geo in
			let padding: CGFloat = 0
			let spacing: CGFloat = 1
			let configuredCols = max(1, filterState.columnCount)
			let configuredRows = max(1, filterState.rowsPerScreen)
			let effectiveCols = min(configuredCols, max(1, panes.count))
			// 1 画面に必要な行数 = ceil(panes / effectiveCols)、これを configuredRows で cap
			let neededRows = max(1, Int(ceil(Double(panes.count) / Double(effectiveCols))))
			let effectiveRows = min(configuredRows, neededRows)
			let totalSpacing = spacing * CGFloat(effectiveRows - 1)
			let availableHeight = geo.size.height - padding * 2
			let cellH = max(80, (availableHeight - totalSpacing) / CGFloat(effectiveRows))

			ScrollView {
				LazyVGrid(columns: gridColumns(spacing: spacing, count: effectiveCols), spacing: spacing) {
					ForEach(panes, id: \.cellKey) { entry in
						TileCell(
							project: entry.project,
							paneId: entry.paneId,
							paneIndex: entry.paneIndex,
							status: entry.status,
							cellHeight: cellH,
							headerHeight: headerHeight,
							commandAreaState: stateManager.state(for: ProjectViewStore.shared.activeView(for: entry.project.id).id)
						)
						.frame(height: cellH)
					}
				}
				.padding(padding)
			}
		}
	}

	private func gridColumns(spacing: CGFloat, count: Int) -> [GridItem] {
		Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
	}

	/// 横並び 1 行レイアウト: tile は available height いっぱい、横スクロール。
	/// 1 つあたりの幅は columnCount で決まる (= 同時に columnCount 個 visible)。
	/// columnCount は **max** 扱い: pane 数が少なければそれに合わせて広い tile に。
	private func horizontalRow(panes: [PaneCellInfo]) -> some View {
		GeometryReader { geo in
			let padding: CGFloat = 0
			let spacing: CGFloat = 1
			let configured = max(1, filterState.columnCount)
			let n = min(configured, max(1, panes.count))
			let totalSpacing = spacing * CGFloat(n - 1)
			let availableWidth = geo.size.width - padding * 2
			let cellWidth = max(160, (availableWidth - totalSpacing) / CGFloat(n))
			let cellH = max(1, geo.size.height - padding * 2)

			ScrollView(.horizontal, showsIndicators: true) {
				LazyHStack(spacing: spacing) {
					ForEach(panes, id: \.cellKey) { entry in
						TileCell(
							project: entry.project,
							paneId: entry.paneId,
							paneIndex: entry.paneIndex,
							status: entry.status,
							cellHeight: cellH,
							headerHeight: headerHeight,
							commandAreaState: stateManager.state(for: ProjectViewStore.shared.activeView(for: entry.project.id).id)
						)
						.frame(width: cellWidth, height: cellH)
					}
				}
				.padding(padding)
			}
		}
	}

	private var visiblePanes: [PaneCellInfo] {
		var result: [PaneCellInfo] = []
		for (projectIdx, project) in projectStore.projects.enumerated() {
			let state = stateManager.state(for: ProjectViewStore.shared.activeView(for: project.id).id)
			let status = agentSessionStore.rollupStatus(forProject: project.id) ?? .idle
			for (paneIdString, paneIndex) in collectLeafPanes(from: state.root) {
				guard filterState.shouldShow(paneId: paneIdString, projectId: project.id, status: status, isPinnedProject: project.isPinned) else {
					continue
				}
				result.append(PaneCellInfo(
					project: project,
					paneId: paneIdString,
					paneIndex: paneIndex,
					status: status,
					projectOrder: projectIdx
				))
			}
		}
		return sortPanes(result)
	}

	private func sortPanes(_ panes: [PaneCellInfo]) -> [PaneCellInfo] {
		filterState.sort(
			panes,
			paneId: { $0.paneId },
			projectOrder: { $0.projectOrder },
			paneIndex: { $0.paneIndex },
			status: { $0.status },
			lastActivity: { lastActivity(paneId: $0.paneId) }
		)
	}

	/// 該当 leaf paneId の bind 先 session の最終更新時刻。
	/// pane→SessionKey binding (`sessionKey(forPane:)`) で session を解決し updatedAt を返す。
	/// paneId は raw のまま渡す (binding 側で lowercase 正規化される)。
	private func lastActivity(paneId: String) -> Date? {
		guard let sessionKey = agentSessionStore.sessionKey(forPane: paneId),
		      let session = agentSessionStore.session(for: sessionKey) else { return nil }
		return session.updatedAt
	}

	/// PaneNode tree から leaf pane (paneId, paneIndex) を再帰収集。
	private func collectLeafPanes(from node: PaneNode) -> [(String, Int)] {
		if node.isLeaf, let paneId = node.paneId {
			return [(paneId.uuidString, node.paneIndex ?? 0)]
		}
		return (node.children ?? []).flatMap { collectLeafPanes(from: $0) }
	}

	/// project 一覧を group ごとにまとめる (filter UI のドロップダウン用)。
	private var groupedProjects: [(group: String, projects: [Project])] {
		let groups = Dictionary(grouping: projectStore.projects) { $0.groupName ?? "" }
		return groups.keys.sorted().map { key in
			(group: key.isEmpty ? "Ungrouped" : key, projects: groups[key] ?? [])
		}
	}
}

private struct PaneCellInfo {
	let project: Project
	let paneId: String
	let paneIndex: Int
	let status: AgentStatus
	let projectOrder: Int

	var cellKey: String { "\(project.id.uuidString)|\(paneId)" }
}

private struct TileCell: View {
	let project: Project
	let paneId: String
	let paneIndex: Int
	let status: AgentStatus
	let cellHeight: CGFloat
	let headerHeight: CGFloat
	@ObservedObject var commandAreaState: CommandAreaState

	@EnvironmentObject var projectStore: ProjectStore
	@ObservedObject private var filterState = TileFilterState.shared


	var body: some View {
		VStack(spacing: 0) {
			if headerHeight > 0 {
				header
					.frame(height: headerHeight)
					.contentShape(Rectangle())
					.onTapGesture { openInProjectView() }
			}

			GeometryReader { geo in
				// クリック / キー入力は WKWebView (becomeFirstResponder) が直接受ける。
				// tile cell では isProjectSelected=false にすることで全 project ZStack
				// の auto-focus 競合を抑える (= ユーザーが明示的にクリックした時のみ focus)。
				XTermTerminalView(
					project: project,
					paneId: paneId,
					paneIndex: paneIndex,
					viewWidth: max(1, geo.size.width),
					viewHeight: max(1, geo.size.height),
					isProjectSelected: false
				)
				.environmentObject(commandAreaState)
				.frame(width: max(1, geo.size.width), height: max(1, geo.size.height))
				.clipped()
			}
		}
		.background(Theme.surface)
		.overlay(
			Rectangle()
				.stroke(isFocused ? Theme.accent : Theme.borderSubtle, lineWidth: isFocused ? 2 : 1)
		)
		.clipShape(Rectangle())
	}

	private var isFocused: Bool {
		filterState.focusedPaneId == paneId
	}

	/// Header 内 element サイズを headerHeight に比例させる。
	/// baseHeader=18 を基準に scale 計算、min/max でクランプ。
	private var iconSize: CGFloat { min(28, max(8, headerHeight * 0.65)) }
	private var textSize: CGFloat { min(20, max(7, headerHeight * 0.55)) }
	private var subTextSize: CGFloat { min(18, max(6, headerHeight * 0.5)) }

	private var header: some View {
		HStack(spacing: 6) {
			StatusIndicator(status: status, sizeOverride: iconSize)
				.padding(.leading, 4)
				.padding(.trailing, 2)
			Text(project.name)
				.font(.system(size: textSize, weight: .medium))
				.foregroundStyle(Theme.textPrimary)
				.lineLimit(1)
			Text("·\(paneIndex + 1)")
				.font(.system(size: subTextSize))
				.foregroundStyle(Theme.textTertiary)
			Spacer()
			hideButton
			pinButton
			closeButton
		}
		.padding(.horizontal, 4)
		.padding(.vertical, 3)
		.background(Theme.surfaceActive.opacity(0.5))
	}

	private var hideButton: some View {
		Button(action: { filterState.hidePane(paneId) }) {
			Image(systemName: "eye.slash")
				.font(.system(size: subTextSize))
				.foregroundStyle(Theme.textTertiary)
		}
		.buttonStyle(.plain)
		.help("Hide this pane (restore from the tray below)")
	}

	private var pinButton: some View {
		let isPinned = filterState.pinnedPaneIds.contains(paneId)
		return Button(action: togglePin) {
			Image(systemName: isPinned ? "pin.fill" : "pin")
				.font(.system(size: subTextSize))
				.foregroundStyle(isPinned ? Theme.accent : Theme.textTertiary)
		}
		.buttonStyle(.plain)
		.help(isPinned ? "Unpin from tile" : "Pin to tile (always visible)")
	}

	private var closeButton: some View {
		Button(action: closeTile) {
			Image(systemName: "xmark")
				.font(.system(size: subTextSize, weight: .medium))
				.foregroundStyle(Theme.textTertiary)
				.padding(.horizontal, 3)
		}
		.buttonStyle(.plain)
		.help("Close pane")
	}

	private func togglePin() {
		if filterState.pinnedPaneIds.contains(paneId) {
			filterState.pinnedPaneIds.remove(paneId)
		} else {
			filterState.pinnedPaneIds.insert(paneId)
		}
	}

	/// Pane を close (= belvePaneClosed → registry unregister + Coordinator deinit
	/// → PTYService が fd close + プロセス kill)。Focus が dead pane を指してたら解除。
	private func closeTile() {
		guard let paneUUID = UUID(uuidString: paneId) else { return }
		if filterState.focusedPaneId == paneId {
			filterState.focusedPaneId = nil
		}
		filterState.pinnedPaneIds.remove(paneId)
		commandAreaState.closePane(paneUUID)
	}

	private func openInProjectView() {
		if let idx = projectStore.projects.firstIndex(where: { $0.id == project.id }) {
			projectStore.selectByIndex(idx)
		}
		withAnimation(ViewMode.toggleAnimation(showing: false)) {
			AppConfig.shared.viewMode = .project
		}
		NotificationCenter.default.post(
			name: .belveTileActivatePane,
			object: nil,
			userInfo: ["projectId": project.id, "paneId": paneId]
		)
	}
}

extension Notification.Name {
	/// Tile cell タップで該当 pane を active にする要求 (CommandArea が受信)。
	static let belveTileActivatePane = Notification.Name("belveTileActivatePane")
}
