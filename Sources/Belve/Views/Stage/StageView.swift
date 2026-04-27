import SwiftUI

/// Stage Manager 風の review 中心 view。center に大きく 1 つ、左に他 agent の card が浮遊。
/// 1 card = 1 agent = 1 pane の前提。
struct StageView: View {
	@EnvironmentObject var projectStore: ProjectStore
	@EnvironmentObject var notificationStore: NotificationStore
	@ObservedObject private var stageState = StageViewState.shared
	@ObservedObject private var registry = PaneHostRegistry.shared
	let stateManager: CommandAreaStateManager
	@Namespace private var stageNamespace

	private let cardWidth: CGFloat = 200
	private let cardHeight: CGFloat = 80
	private let cardSpacing: CGFloat = 10
	private let centerPadding: CGFloat = 20
	private let offstageColumnWidth: CGFloat = 220

	var body: some View {
		HStack(spacing: 0) {
			// Off-stage cards (左列)
			offStageColumn
				.padding(.leading, 12)
				.padding(.top, 12)
				.frame(width: offstageColumnWidth, alignment: .topLeading)

			// Center stage (中央、残り全部)
			centerStage
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.padding(centerPadding)
		}
		.overlay(alignment: .bottomTrailing) {
			newAgentFAB
				.padding(20)
		}
		.background(Theme.bg)
	}

	private var newAgentFAB: some View {
		Button(action: spawnNewAgent) {
			Image(systemName: "plus")
				.font(.system(size: 18, weight: .semibold))
				.foregroundStyle(Color.white)
				.frame(width: 48, height: 48)
				.background(
					Circle()
						.fill(Theme.accent)
						.shadow(color: .black.opacity(0.25), radius: 8, y: 3)
				)
		}
		.buttonStyle(.plain)
		.help("Spawn new agent in current project")
	}

	/// 現在 center stage の project (= 何も無ければ sidebar 1 番目) に新 pane を spawn し
	/// 即 center に。
	private func spawnNewAgent() {
		// 起動先 project を決定
		let targetProject: Project?
		if let centerId = stageState.centerPaneId,
		   let entry = resolveEntry(paneId: centerId) {
			targetProject = entry.project
		} else {
			targetProject = projectStore.projects.first
		}
		guard let project = targetProject else { return }

		let state = stateManager.state(for: project.id)
		guard let newPaneId = state.spawnNewPane() else { return }
		// SwiftUI が新 pane を mount するのを待ってから center に promote
		DispatchQueue.main.async {
			withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
				stageState.promoteToCenter(newPaneId.uuidString)
			}
		}
	}

	// MARK: - Off-stage column

	private var offStageColumn: some View {
		GeometryReader { geo in
			let panes = offStagePanes
			let normalCount = computeNormalCount(totalCards: panes.count, availableHeight: geo.size.height)
			let positions = computePositions(
				totalCards: panes.count,
				normalCount: normalCount,
				availableHeight: geo.size.height
			)
			ZStack(alignment: .topLeading) {
				ForEach(Array(panes.enumerated()), id: \.element.paneId) { idx, entry in
					OffStageCard(
						project: entry.project,
						paneId: entry.paneId,
						paneIndex: entry.paneIndex,
						namespace: stageNamespace,
						onSelect: { promoteToCenter(paneId: entry.paneId) }
					)
					.frame(width: cardWidth, height: cardHeight)
					.scaleEffect(scale(for: idx, normalCount: normalCount), anchor: .top)
					.opacity(opacity(for: idx, normalCount: normalCount))
					.position(x: cardWidth / 2, y: positions[idx] + cardHeight / 2)
					.zIndex(Double(panes.count - idx))
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
	}

	/// 各 card の Y 位置を一括計算。
	/// - idx < normalCount: 通常 spacing
	/// - idx >= normalCount: 残り stacking zone (= 画面残り高さ) を decay weight で配分
	///   → ウィンドウサイズに収まるように自動圧縮、下に行くほど step 小さく (overlap 強)
	private func computePositions(totalCards: Int, normalCount: Int, availableHeight: CGFloat) -> [CGFloat] {
		var positions: [CGFloat] = []
		let normalStep = cardHeight + cardSpacing
		positions.reserveCapacity(totalCards)
		for idx in 0..<normalCount {
			positions.append(CGFloat(idx) * normalStep)
		}
		let overflowCount = totalCards - normalCount
		if overflowCount <= 0 { return positions }

		let lastNormalY = CGFloat(max(0, normalCount - 1)) * normalStep
		let bottomMargin: CGFloat = 8
		let zoneHeight = max(0, availableHeight - lastNormalY - cardHeight - bottomMargin)

		// Zone の高さから逆算する **線形 decay**:
		//   step(k) = a - b*k  (= 上が大、下に行くほど小、k=0..O-1)
		//   合計 = O*(a + step_last)/2 = zoneHeight
		//
		// Case 1: zone が広め (= O 個 normal slot 入る余裕あり)
		//   step[0] = normalStep に固定、b は naive 計算で zone を埋める
		// Case 2: zone が狭く naive で last step が minPeek を割る
		//   step[0] を下げて last step = minPeek、zone を埋める
		// Case 3: zone が広すぎ (zone >= O*normalStep)
		//   全 overflow を normal spacing で配置 (= 余白を許容)
		let O = CGFloat(overflowCount)
		let oMinus1 = max(1.0, CGFloat(overflowCount - 1))

		var a: CGFloat   // step[0]
		var b: CGFloat   // 各 step の減少量

		if zoneHeight >= O * normalStep {
			// Case 3: no stacking 必要、全部 normal
			a = normalStep
			b = 0
		} else {
			let naiveB = 2 * (O * normalStep - zoneHeight) / (O * oMinus1)
			let naiveLast = normalStep - oMinus1 * naiveB
			if naiveLast >= Self.stackMinPeek {
				// Case 1
				a = normalStep
				b = naiveB
			} else {
				// Case 2: step[0] を下げて last = minPeek、zone を埋める
				a = 2 * zoneHeight / O - Self.stackMinPeek
				b = (a - Self.stackMinPeek) / oMinus1
			}
		}

		var pos = lastNormalY
		for k in 0..<overflowCount {
			let step = max(Self.stackMinPeek, a - CGFloat(k) * b)
			pos += step
			positions.append(pos)
		}
		return positions
	}

	/// 「絶対崩れない top N 枚」の数を計算。固定上限 5 枚 (window 大きくても増やさない)。
	/// 小さい window で 5 枚入らなければ height ベースで減らす。
	private static let maxNormalCards = 5

	private func computeNormalCount(totalCards: Int, availableHeight: CGFloat) -> Int {
		let heightSlots = max(1, Int((availableHeight + cardSpacing) / (cardHeight + cardSpacing)))
		let cap = min(Self.maxNormalCards, heightSlots)
		return min(totalCards, cap)
	}

	private static let stackDecay: CGFloat = 0.65
	private static let stackMinPeek: CGFloat = 6

	private func scale(for idx: Int, normalCount: Int) -> CGFloat {
		if idx < normalCount { return 1.0 }
		let depth = idx - normalCount + 1
		return max(0.92, 1.0 - CGFloat(depth) * 0.015)
	}

	private func opacity(for idx: Int, normalCount: Int) -> Double {
		if idx < normalCount { return 1.0 }
		let depth = idx - normalCount + 1
		return max(0.5, 1.0 - Double(depth) * 0.08)
	}

	// MARK: - Center stage

	@ViewBuilder
	private var centerStage: some View {
		if let paneId = stageState.centerPaneId,
		   let entry = resolveEntry(paneId: paneId) {
			CenterStageCard(
				project: entry.project,
				paneId: entry.paneId,
				paneIndex: entry.paneIndex,
				commandAreaState: stateManager.state(for: entry.project.id),
				namespace: stageNamespace
			)
			// .id(paneId) で paneId 変化時に SwiftUI に view identity 変更を伝える。
			// これがないと NSViewRepresentable の WebView が swap されず、前の terminal
			// が出続ける (registry は新 paneId 解決してても表示は古 NSView のまま)。
			.id(paneId)
		} else {
			emptyCenterPlaceholder
		}
	}

	private var emptyCenterPlaceholder: some View {
		VStack(spacing: 12) {
			Image(systemName: "rectangle.dashed")
				.font(.system(size: 36, weight: .light))
				.foregroundStyle(Theme.textTertiary)
			Text("Pick an agent from the left, or spawn a new one")
				.font(.system(size: 13))
				.foregroundStyle(Theme.textTertiary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Theme.surface.opacity(0.4))
		.clipShape(RoundedRectangle(cornerRadius: 10))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Theme.borderSubtle, lineWidth: 1)
		)
	}

	// MARK: - Pane enumeration

	/// Off-stage 表示順: **status 優先順** (report 待ちが上、active 真ん中、idle 下)。
	/// 同 status 内は project 順 × pane index 順で安定 sort。
	/// dismissed と center は除外。
	private var offStagePanes: [PaneEntry] {
		let allEntries = collectAllEntries()
		let centerId = stageState.centerPaneId
		let dismissed = stageState.dismissedPaneIds
		let visible = allEntries.enumerated().compactMap { idx, entry -> (Int, PaneEntry, AgentStatus)? in
			guard entry.paneId != centerId, !dismissed.contains(entry.paneId) else { return nil }
			let status = notificationStore.currentSession(forPaneId: entry.paneId)?.status ?? .idle
			return (idx, entry, status)
		}
		return visible.sorted { lhs, rhs in
			let lp = Self.stagePriority(lhs.2)
			let rp = Self.stagePriority(rhs.2)
			if lp != rp { return lp < rp }
			return lhs.0 < rhs.0   // 元の collect 順 (= project × pane index)
		}.map { $0.1 }
	}

	/// Stage view の status 優先度 (= 上に出したい順):
	/// waiting / completed / sessionEnd (report 待ち) が最上位、
	/// active (running 系) が真ん中、idle 系が最下位。
	static func stagePriority(_ s: AgentStatus) -> Int {
		switch s {
		case .waiting: return 0
		case .completed, .sessionEnd: return 1
		case .running: return 2
		case .runningSubagent: return 3
		case .sessionStart: return 4
		case .idle: return 5
		}
	}

	private func resolveEntry(paneId: String) -> PaneEntry? {
		collectAllEntries().first(where: { $0.paneId == paneId })
	}

	private func collectAllEntries() -> [PaneEntry] {
		var result: [PaneEntry] = []
		for project in projectStore.projects {
			let state = stateManager.state(for: project.id)
			for (paneIdString, paneIndex) in collectLeafPanes(from: state.root) {
				result.append(PaneEntry(project: project, paneId: paneIdString, paneIndex: paneIndex))
			}
		}
		return result
	}

	private func collectLeafPanes(from node: PaneNode) -> [(String, Int)] {
		if node.isLeaf, let paneId = node.paneId {
			return [(paneId.uuidString, node.paneIndex ?? 0)]
		}
		return (node.children ?? []).flatMap { collectLeafPanes(from: $0) }
	}

	// MARK: - Actions

	private func promoteToCenter(paneId: String) {
		NSLog("[Belve][stage] promoteToCenter pane=%@", paneId)
		withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
			stageState.promoteToCenter(paneId)
		}
		// Animation 完了後に該当 project の terminal refit を強制 (= scrollback も
		// 新サイズに reflow)。.id(paneId) による view rebuild + hero animation で
		// 中間サイズを経由するため、最終 fit が古いサイズで止まることを回避。
		if let entry = resolveEntry(paneId: paneId) {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
				NotificationCenter.default.post(
					name: .belveTerminalRefit,
					object: nil,
					userInfo: ["projectId": entry.project.id]
				)
			}
		}
	}
}

// MARK: - Pane entry helper

private struct PaneEntry {
	let project: Project
	let paneId: String
	let paneIndex: Int
}

// MARK: - Off-stage card

private struct OffStageCard: View {
	let project: Project
	let paneId: String
	let paneIndex: Int
	let namespace: Namespace.ID
	let onSelect: () -> Void

	@EnvironmentObject var notificationStore: NotificationStore
	@State private var pulse = false

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			VStack {
				StatusIndicator(status: displayStatus, sizeOverride: 14)
				Spacer()
			}
			.frame(width: 18)
			.padding(.top, 2)

			VStack(alignment: .leading, spacing: 3) {
				Text("\(project.name) · \(paneIndex + 1)")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
					.lineLimit(1)
				Text(primaryText)
					.font(.system(size: 10))
					.foregroundStyle(Theme.textSecondary)
					.lineLimit(1)
				if let detail = detailText {
					HStack(spacing: 3) {
						if let tool = session?.currentTool {
							Image(systemName: "wrench.and.screwdriver")
								.font(.system(size: 8))
								.foregroundStyle(Theme.accent)
							Text(tool)
								.font(.system(size: 9))
								.foregroundStyle(Theme.accent)
								.lineLimit(1)
							Text(detail)
								.font(.system(size: 9))
								.foregroundStyle(Theme.textTertiary)
								.lineLimit(1)
						} else {
							Text(detail)
								.font(.system(size: 9))
								.foregroundStyle(detailColor)
								.lineLimit(1)
						}
					}
				}
				Spacer()
			}
		}
		.padding(8)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(Theme.surface)
		.clipShape(RoundedRectangle(cornerRadius: 8))
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(borderColor, lineWidth: needsAttention ? 2 : 1)
		)
		.overlay(alignment: .topTrailing) {
			if needsAttention {
				readyBadge
					.padding(6)
			}
		}
		.matchedGeometryEffect(id: paneId, in: namespace)
		.contentShape(Rectangle())
		.onTapGesture { onSelect() }
		.onAppear {
			withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
				pulse = true
			}
		}
	}

	/// waiting (= ユーザー入力待ち) または completed/sessionEnd (= 完了報告) は
	/// review してほしい card → 強調表示。
	private var needsAttention: Bool {
		switch status {
		case .waiting, .completed, .sessionEnd: return true
		default: return false
		}
	}

	private var borderColor: Color {
		needsAttention ? Theme.accent.opacity(pulse ? 1.0 : 0.5) : Theme.borderSubtle
	}

	private var readyBadge: some View {
		Image(systemName: "checkmark.circle.fill")
			.font(.system(size: 12, weight: .semibold))
			.foregroundStyle(Color.white, Theme.accent)
			.opacity(pulse ? 1.0 : 0.6)
	}

	private var session: AgentSession? {
		notificationStore.currentSession(forPaneId: paneId)
	}

	/// 生 status (sort / attention 判定用)。subagent override は表示側 (displayStatus) でのみ。
	private var status: AgentStatus {
		session?.status ?? .idle
	}

	/// SessionRow と同じ流儀: subagent 走行中は親 status より優先表示。
	private var displayStatus: AgentStatus {
		guard let s = session else { return .idle }
		return s.subagentCount > 0 ? .runningSubagent : s.status
	}

	/// SessionRow.primaryText と同じ優先順位: lastUserPrompt → label → "Ready" → message。
	private var primaryText: String {
		if let s = session {
			if let prompt = s.lastUserPrompt, !prompt.isEmpty { return prompt }
			if let label = s.label, !label.isEmpty { return label }
			if s.status == .sessionStart { return "Ready" }
			if !s.message.isEmpty { return s.message }
		}
		return "Idle"
	}

	/// 2 行目: tool / lastAgentActivity / waiting message のいずれか。
	private var detailText: String? {
		guard let s = session else { return nil }
		if let activity = s.lastAgentActivity, !activity.isEmpty { return activity }
		if s.status == .waiting, !s.message.isEmpty { return s.message }
		if s.status == .completed, !s.message.isEmpty, s.message != "Done" { return s.message }
		if s.subagentCount > 0 { return "subagent ×\(s.subagentCount)" }
		return nil
	}

	private var detailColor: Color {
		guard let s = session else { return Theme.textTertiary }
		return s.status == .waiting ? Theme.yellow : Theme.textTertiary
	}
}

// MARK: - Center stage card

private struct CenterStageCard: View {
	let project: Project
	let paneId: String
	let paneIndex: Int
	let commandAreaState: CommandAreaState
	let namespace: Namespace.ID

	@EnvironmentObject var notificationStore: NotificationStore

	var body: some View {
		VStack(spacing: 0) {
			header
				.frame(height: 36)
			Theme.borderSubtle.frame(height: 1)
			// GeometryReader を使わない: animation 中の中間サイズで XTermTerminalView の
			// viewWidth/Height が変動するのを抑制 → resizeTerminal が走らない →
			// xterm.js の reflow が animation 中に複数回起きて scrollback を破壊するのを回避。
			// 最終 fit は StageView.promoteToCenter が 0.55s 後に発行する
			// belveTerminalRefit notification 1 回だけで行う。
			XTermTerminalView(
				project: project,
				paneId: paneId,
				paneIndex: paneIndex,
				viewWidth: 0,    // sentinel: updateNSView の resize 分岐を skip
				viewHeight: 0,
				isProjectSelected: false
			)
			.environmentObject(commandAreaState)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.clipped()
		}
		.background(Theme.surface)
		.clipShape(RoundedRectangle(cornerRadius: 10))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Theme.borderSubtle, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.18), radius: 12, y: 6)
		.matchedGeometryEffect(id: paneId, in: namespace)
	}

	private var header: some View {
		HStack(spacing: 8) {
			StatusIndicator(status: status, sizeOverride: 14)
				.padding(.leading, 12)
			VStack(alignment: .leading, spacing: 1) {
				Text(project.name)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
				Text("Pane \(paneIndex + 1)")
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary)
			}
			Spacer()
			Button(action: { StageViewState.shared.dismiss(paneId) }) {
				Image(systemName: "xmark")
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(Theme.textTertiary)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
			}
			.buttonStyle(.plain)
			.help("Dismiss from stage (pane stays alive)")
			.padding(.trailing, 6)
		}
		.background(Theme.surfaceActive.opacity(0.5))
	}

	private var status: AgentStatus {
		guard let s = notificationStore.currentSession(forPaneId: paneId) else { return .idle }
		return s.subagentCount > 0 ? .runningSubagent : s.status
	}
}
