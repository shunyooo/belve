import SwiftUI

/// Agent Dock: 全 companion が 1 つの dock bar に横並びで収まる。
/// 各 agent の avatar が並び、発話中の agent の上に speech bubble が出る。
struct AgentDockView: View {
	@ObservedObject var store = AgentCompanionStore.shared
	@ObservedObject var notificationStore: NotificationStore
	/// Bubble 表示状態。`.auto` = 新発話で自動表示、N 秒で消える。`.pinned` = tap で固定。
	enum BubbleState { case auto(expiry: Date), pinned }
	@State private var visibleBubbles: [String: BubbleState] = [:]
	@State private var expandedBubbles: Set<String> = []
	/// 前回観測した messages count (= 新発話検出用)
	@State private var lastMessageCounts: [String: Int] = [:]
	/// Dock bar の幅。agent 数に auto-fit。
	@State private var dockWidthOverride: CGFloat? = nil
	private let autoDisplayDuration: TimeInterval = 8
	private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

	private let slotWidth: CGFloat = 84  // avatar 72 + spacing 12
	private let dockPadding: CGFloat = 32 // 左右 padding 合計

	/// Agent 数に応じた auto-fit 幅。override があればそちら優先。
	private func effectiveDockWidth(agentCount: Int) -> CGFloat {
		if let w = dockWidthOverride { return w }
		let fit = CGFloat(max(1, agentCount)) * slotWidth + dockPadding
		return max(160, min(fit, 800))
	}

	var body: some View {
		let projectOrder = store.projectOrder
		let companions = Array(store.companions.values).sorted { a, b in
			let ia = projectOrder.firstIndex(of: a.projectId) ?? Int.max
			let ib = projectOrder.firstIndex(of: b.projectId) ?? Int.max
			if ia != ib { return ia < ib }
			return a.paneId < b.paneId
		}
		let dockWidth = effectiveDockWidth(agentCount: companions.count)
		VStack(spacing: 0) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(alignment: .bottom, spacing: 12) {
					ForEach(companions) { companion in
						agentSlot(companion)
					}
				}
				.padding(.horizontal, 16)
				.frame(maxWidth: .infinity)
			}
			.padding(.vertical, 10)
			.padding(.top, 4)
			.frame(width: dockWidth)
			.background(
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.fill(.ultraThinMaterial)
					.environment(\.colorScheme, .dark)
					.overlay(
						RoundedRectangle(cornerRadius: 16, style: .continuous)
							.stroke(Theme.border.opacity(0.3), lineWidth: 1)
					)
					.shadow(color: .black.opacity(0.3), radius: 8, y: 2)
			)
		}
		// 新発話検出 → auto-show (onChange は NSHostingController で発火しないため
		// Combine publisher 経由で observe する)
		.onReceive(store.$companions) { newVal in
			for (paneId, companion) in newVal {
				let oldCount = lastMessageCounts[paneId] ?? 0
				let newCount = companion.messages.count
				if newCount > oldCount && hasBubbleContent(companion) {
					withAnimation(.easeOut(duration: 0.2)) {
						visibleBubbles[paneId] = .auto(expiry: Date().addingTimeInterval(autoDisplayDuration))
					}
				}
				lastMessageCounts[paneId] = newCount
			}
		}
		// Auto-expire timer
		.onReceive(timer) { _ in
			let now = Date()
			var expired: [String] = []
			for (paneId, state) in visibleBubbles {
				if case .auto(let expiry) = state, now > expiry {
					expired.append(paneId)
				}
			}
			if !expired.isEmpty {
				withAnimation(.easeOut(duration: 0.3)) {
					for paneId in expired {
						visibleBubbles.removeValue(forKey: paneId)
					}
				}
			}
		}
	}

	// MARK: - Agent slot (= 1 個の avatar + label)

	private func agentSlot(_ companion: AgentCompanion) -> some View {
		let showBubble = visibleBubbles[companion.paneId] != nil && hasBubbleContent(companion)
		let isPinned = { if case .pinned = visibleBubbles[companion.paneId] { return true }; return false }()
		let isSelected = store.isSelected(companion.paneId)
		return VStack(spacing: 4) {
			StatusIndicator(
				status: companion.status,
				styleOverride: companion.avatarStyle,
				sizeOverride: 42
			)
			.frame(width: 42, height: 42)
			.background(
				Circle()
					.fill(isPinned ? Theme.accent.opacity(0.15) : (showBubble ? Theme.accent.opacity(0.08) : Color.clear))
					.frame(width: 50, height: 50)
			)
			.overlay(
				Circle()
					.stroke(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
					.frame(width: 52, height: 52)
			)
			// Bubble: この avatar の真上に表示。overlay で相対配置。
			.overlay(alignment: .bottom) {
				if showBubble {
					bubbleView(companion)
						.offset(y: -56)
						.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}

			Text(companion.projectName)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(showBubble ? Theme.textPrimary : Theme.textSecondary)
				.lineLimit(2)
				.multilineTextAlignment(.center)
				.frame(width: 72, height: 28, alignment: .top)
		}
		.contentShape(Rectangle())
		.onTapGesture {
			let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
			if mods.contains(.command) {
				store.toggleSelection(companion.paneId)
			} else {
				withAnimation(.easeOut(duration: 0.15)) {
					// Tap → pin toggle (= pinned なら解除、それ以外なら pin)
					if case .pinned = visibleBubbles[companion.paneId] {
						visibleBubbles.removeValue(forKey: companion.paneId)
					} else {
						visibleBubbles[companion.paneId] = .pinned
					}
					expandedBubbles.remove(companion.paneId)
				}
				store.clearSelection()
				focusInMainApp(companion)
			}
		}
		.contextMenu {
			Button("Change Avatar") {
				store.cycleAvatar(companion.paneId)
			}
			Divider()
			Button("Hide from Dock") {
				store.dismissManually(companion.paneId)
			}
		}
	}

	// MARK: - Speech bubble

	private func bubbleView(_ companion: AgentCompanion) -> some View {
		let isExpanded = expandedBubbles.contains(companion.paneId)
		return ScrollView(.vertical, showsIndicators: false) {
			VStack(alignment: .leading, spacing: 4) {
				// 誰の bubble か明示
				Text(companion.projectName)
					.font(.system(size: 10, weight: .bold))
					.foregroundStyle(Theme.accent)

				// User prompt
				if !companion.userPrompt.isEmpty {
					HStack(alignment: .top, spacing: 4) {
						Text(">")
							.font(.system(size: 11, weight: .bold, design: .monospaced))
							.foregroundStyle(Theme.yellow)
						Text(Self.attributed(companion.userPrompt))
							.font(.system(size: 11))
							.foregroundStyle(Theme.textSecondary)
							.lineLimit(isExpanded ? nil : 2)
					}
				}

				// Agent messages
				ForEach(companion.messages) { msg in
					Text(Self.attributed(msg.text))
						.font(.system(size: 12, weight: .medium))
						.foregroundStyle(Theme.textPrimary)
						.lineLimit(isExpanded ? nil : 4)
				}

				// Tool
				if let tool = companion.currentTool {
					HStack(spacing: 4) {
						Image(systemName: "wrench.and.screwdriver")
							.font(.system(size: 8))
						Text(tool)
							.lineLimit(1)
					}
					.font(.system(size: 9))
					.foregroundStyle(Theme.accent.opacity(0.8))
				}
			}
		}
		.frame(maxWidth: effectiveDockWidth(agentCount: store.companions.count) - 24, maxHeight: isExpanded ? 300 : nil, alignment: .leading)
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(
			SpeechBubbleShape(tailOnLeft: false, tailOnBottom: true)
				.fill(Theme.surface.opacity(0.95))
				.overlay(
					SpeechBubbleShape(tailOnLeft: false, tailOnBottom: true)
						.stroke(borderColor(for: companion).opacity(0.3), lineWidth: 1)
				)
				.shadow(color: .black.opacity(0.15), radius: 4, y: 1)
		)
		.textSelection(.enabled)
		.onTapGesture {
			withAnimation(.easeOut(duration: 0.15)) {
				if expandedBubbles.contains(companion.paneId) {
					expandedBubbles.remove(companion.paneId)
				} else {
					expandedBubbles.insert(companion.paneId)
				}
			}
		}
		.padding(.bottom, 6)
	}

	// MARK: - Helpers

	private func hasBubbleContent(_ companion: AgentCompanion) -> Bool {
		!companion.messages.isEmpty || companion.currentTool != nil
	}

	private func borderColor(for companion: AgentCompanion) -> Color {
		switch companion.status {
		case .running, .runningSubagent: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed, .sessionEnd: return Theme.green
		default: return Theme.borderSubtle
		}
	}

	private func focusInMainApp(_ companion: AgentCompanion) {
		NSApp.activate(ignoringOtherApps: true)
		NotificationCenter.default.post(
			name: .belveFocusProject,
			object: nil,
			userInfo: ["projectId": companion.projectId]
		)
		NotificationCenter.default.post(
			name: .belveTileActivatePane,
			object: nil,
			userInfo: ["projectId": companion.projectId, "paneId": companion.paneId]
		)
	}

	static func attributed(_ text: String) -> AttributedString {
		let opts = AttributedString.MarkdownParsingOptions(
			interpretedSyntax: .inlineOnlyPreservingWhitespace
		)
		if let attr = try? AttributedString(markdown: text, options: opts) {
			return attr
		}
		return AttributedString(text)
	}
}

private extension Double {
	func nonZeroOrDefault(_ d: Double) -> Double { self > 0 ? self : d }
}

/// 吹き出し Shape。tailOnBottom=true で下に三角が出る (= dock bar の上に表示する用)。
private struct SpeechBubbleShape: Shape {
	let tailOnLeft: Bool
	var tailOnBottom: Bool = false
	private let cornerRadius: CGFloat = 10
	private let tailWidth: CGFloat = 8
	private let tailHeight: CGFloat = 6

	func path(in rect: CGRect) -> Path {
		var path = Path()
		let r = cornerRadius
		path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
		if tailOnBottom {
			let tailX = rect.midX - tailWidth / 2
			path.move(to: CGPoint(x: tailX, y: rect.maxY))
			path.addLine(to: CGPoint(x: tailX + tailWidth / 2, y: rect.maxY + tailHeight))
			path.addLine(to: CGPoint(x: tailX + tailWidth, y: rect.maxY))
			path.closeSubpath()
		} else if tailOnLeft {
			let tailY = rect.midY - tailHeight / 2
			path.move(to: CGPoint(x: rect.minX, y: tailY))
			path.addLine(to: CGPoint(x: rect.minX - tailWidth, y: tailY + tailHeight / 2))
			path.addLine(to: CGPoint(x: rect.minX, y: tailY + tailHeight))
			path.closeSubpath()
		}
		return path
	}
}
