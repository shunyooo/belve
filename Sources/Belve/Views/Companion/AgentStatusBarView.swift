import SwiftUI

struct AgentStatusBarView: View {
	@ObservedObject var store = AgentCompanionStore.shared
	@ObservedObject var notificationStore: NotificationStore
	@State private var isExpanded = false
	@State private var previousStatuses: [String: AgentStatus] = [:]
	@State private var previousTools: [String: String] = [:]
	@State private var previousMessageCounts: [String: Int] = [:]
	@State private var flashingPanes: Set<String> = []
	@State private var transitionMessages: [String: String] = [:]
	@State private var transitionExpiry: [String: Date] = [:]
	@State private var waitingPulse: Bool = false
	private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

	private struct ProjectGroup: Identifiable {
		let id: UUID
		let name: String
		let companions: [AgentCompanion]
		var bestStatus: AgentStatus {
			// 優先度: waiting > running > completed > idle
			let priority: [AgentStatus: Int] = [.waiting: 4, .running: 3, .runningSubagent: 3, .completed: 2, .sessionStart: 1, .idle: 0, .sessionEnd: 0]
			return companions.max(by: { (priority[$0.status] ?? 0) < (priority[$1.status] ?? 0) })?.status ?? .idle
		}
		var hasBackground: Bool {
			companions.contains { $0.currentTool == "Background" }
		}
		var bestCompanion: AgentCompanion? {
			let priority: [AgentStatus: Int] = [.waiting: 4, .running: 3, .runningSubagent: 3, .completed: 2, .sessionStart: 1, .idle: 0, .sessionEnd: 0]
			return companions.max(by: { (priority[$0.status] ?? 0) < (priority[$1.status] ?? 0) })
		}
	}

	private var projectGroups: [ProjectGroup] {
		let projectOrder = store.projectOrder
		let allCompanions = Array(store.companions.values)
		var groupDict: [UUID: [AgentCompanion]] = [:]
		for c in allCompanions { groupDict[c.projectId, default: []].append(c) }
		var result: [ProjectGroup] = []
		for pid in projectOrder {
			if let comps = groupDict[pid], !comps.isEmpty {
				result.append(ProjectGroup(id: pid, name: comps[0].projectName, companions: comps))
			}
		}
		for pid in groupDict.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
			if !projectOrder.contains(pid), let comps = groupDict[pid] {
				result.append(ProjectGroup(id: pid, name: comps[0].projectName, companions: comps))
			}
		}
		return result
	}

	var body: some View {
		let companions = projectGroups

		VStack(spacing: 0) {
			VStack(spacing: 4) {
				collapsedBar(companions)
				messageToast(companions)
				if isExpanded {
					expandedView(companions)
						.transition(.move(edge: .top).combined(with: .opacity))
				}
			}
			Spacer()
		}
		.onReceive(store.$companions) { newVal in
			detectTransitions(newVal)
		}
		.onReceive(timer) { _ in
			expireTransitions()
		}
		.onAppear {
			withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
				waitingPulse = true
			}
		}
	}

	// MARK: - Collapsed bar

	private func collapsedBar(_ groups: [ProjectGroup]) -> some View {
		HStack(spacing: 10) {
			ForEach(groups) { group in
				groupDot(group)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 6)
		.background(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(Theme.surface.opacity(0.92))
				.environment(\.colorScheme, .dark)
				.overlay(
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.stroke(Theme.border.opacity(0.4), lineWidth: 1)
				)
				.shadow(color: .black.opacity(0.25), radius: 6, y: 2)
		)
		.contentShape(Rectangle())
		.onTapGesture {
			withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
				isExpanded.toggle()
			}
		}
	}

	private func groupDot(_ group: ProjectGroup) -> some View {
		let anyFlashing = group.companions.contains { flashingPanes.contains($0.paneId) }
		let isWaiting = group.bestStatus == .waiting
		let message = group.companions.lazy.compactMap { transitionMessages[$0.paneId] }.first
		let activeCount = group.companions.filter { $0.status == .running || $0.status == .runningSubagent || $0.status == .waiting }.count

		return HStack(spacing: 4) {
			ZStack {
				Circle()
					.fill(groupDotColor(group))
					.frame(width: 8, height: 8)
				if group.hasBackground {
					Circle()
						.fill(Theme.bg.opacity(0.5))
						.frame(width: 4, height: 4)
				}
			}
			.scaleEffect(anyFlashing ? 1.4 : (isWaiting && waitingPulse ? 1.2 : 1.0))
			.animation(.easeInOut(duration: 0.3), value: anyFlashing)

			Text(group.name)
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(anyFlashing || isWaiting ? Theme.textPrimary : Theme.textSecondary)
				.lineLimit(1)
				.fixedSize(horizontal: true, vertical: false)

			if activeCount > 1 {
				Text("×\(activeCount)")
					.font(.system(size: 8, weight: .medium))
					.foregroundStyle(Theme.textTertiary)
			}

			}
	}

	// MARK: - Message toast (bar の下にスライドダウン)

	@ViewBuilder
	private func messageToast(_ groups: [ProjectGroup]) -> some View {
		// 全グループから最新の transition message を集める
		let activeMessages: [(name: String, msg: String, color: Color)] = groups.compactMap { group in
			guard let msg = group.companions.lazy.compactMap({ transitionMessages[$0.paneId] }).first else { return nil }
			return (name: group.name, msg: msg, color: groupTextColor(group))
		}
		if !activeMessages.isEmpty {
			VStack(spacing: 2) {
				ForEach(activeMessages, id: \.name) { item in
					HStack(spacing: 6) {
						Text(item.name)
							.font(.system(size: 9, weight: .semibold))
							.foregroundStyle(item.color)
						Text(item.msg)
							.font(.system(size: 9))
							.foregroundStyle(Theme.textPrimary)
							.lineLimit(1)
					}
					.padding(.horizontal, 10)
					.padding(.vertical, 3)
					.background(
						Capsule().fill(item.color.opacity(0.1))
					)
					.transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .top)))
				}
			}
		}
	}

	// MARK: - Expanded view

	private func expandedView(_ groups: [ProjectGroup]) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(groups) { group in
				if let companion = group.bestCompanion {
					let activeCount = group.companions.filter { $0.status == .running || $0.status == .runningSubagent || $0.status == .waiting }.count
					expandedRow(companion, activeCount: activeCount)
				}
				if group.id != groups.last?.id {
					Divider().overlay(Theme.borderSubtle.opacity(0.3))
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.vertical, 4)
		.background(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(Theme.surface.opacity(0.92))
				.environment(\.colorScheme, .dark)
				.overlay(
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.stroke(Theme.border.opacity(0.4), lineWidth: 1)
				)
				.shadow(color: .black.opacity(0.25), radius: 6, y: 2)
		)
	}

	private func expandedRow(_ companion: AgentCompanion, activeCount: Int = 0) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Circle()
				.fill(dotColor(for: companion))
				.frame(width: 8, height: 8)
				.padding(.top, 4)

			VStack(alignment: .leading, spacing: 2) {
				HStack {
					Text(companion.projectName)
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(Theme.textPrimary)
					if activeCount > 1 {
						Text("×\(activeCount)")
							.font(.system(size: 9))
							.foregroundStyle(Theme.textTertiary)
					}
					Spacer()
					Text(statusLabel(for: companion))
						.font(.system(size: 9, weight: .medium))
						.foregroundStyle(statusTextColor(for: companion))
						.padding(.horizontal, 6)
						.padding(.vertical, 1)
						.background(
							Capsule().fill(statusTextColor(for: companion).opacity(0.15))
						)
				}

				if !companion.userPrompt.isEmpty {
					Text(companion.userPrompt)
						.font(.system(size: 10))
						.foregroundStyle(Theme.textSecondary)
						.lineLimit(1)
				}

				if companion.currentTool == "Background" {
					HStack(spacing: 3) {
						Image(systemName: "hourglass")
							.font(.system(size: 8))
						Text(companion.messages.last?.text ?? "tasks running")
							.lineLimit(1)
					}
					.font(.system(size: 9))
					.foregroundStyle(Theme.accent.opacity(0.6))
				} else if let tool = companion.currentTool {
					HStack(spacing: 3) {
						Image(systemName: "wrench.and.screwdriver")
							.font(.system(size: 8))
						Text(tool)
							.lineLimit(1)
					}
					.font(.system(size: 9))
					.foregroundStyle(Theme.accent)
				} else if companion.status == .waiting {
					Text(companion.messages.last?.text ?? "Waiting for input")
						.font(.system(size: 9))
						.foregroundStyle(Theme.yellow)
						.lineLimit(1)
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.contentShape(Rectangle())
		.onTapGesture {
			focusInMainApp(companion)
		}
	}

	// MARK: - State transition detection

	private func detectTransitions(_ newCompanions: [String: AgentCompanion]) {
		for (paneId, companion) in newCompanions {
			let prevStatus = previousStatuses[paneId]
			let prevTool = previousTools[paneId]
			let prevMsgCount = previousMessageCounts[paneId] ?? 0
			let currStatus = companion.status
			let currTool = companion.currentTool ?? ""
			let currMsgCount = companion.messages.count
			let statusChanged = prevStatus != nil && prevStatus != currStatus
			let toolChanged = prevTool != nil && prevTool != currTool && !currTool.isEmpty
			let messageAdded = currMsgCount > prevMsgCount
			if statusChanged || toolChanged || messageAdded {
				let text: String
				if messageAdded, let lastMsg = companion.messages.last?.text, !lastMsg.isEmpty {
					text = lastMsg.prefix(60).description + (lastMsg.count > 60 ? "…" : "")
				} else {
					text = transitionText(for: companion)
				}
				if !text.isEmpty {
					withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
						flashingPanes.insert(paneId)
						transitionMessages[paneId] = text
						transitionExpiry[paneId] = Date().addingTimeInterval(4)
					}
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
						_ = withAnimation(.easeOut(duration: 0.4)) {
							flashingPanes.remove(paneId)
						}
					}
				}
			}
			previousStatuses[paneId] = currStatus
			previousTools[paneId] = currTool
			previousMessageCounts[paneId] = currMsgCount
		}
		for paneId in previousStatuses.keys where newCompanions[paneId] == nil {
			previousStatuses.removeValue(forKey: paneId)
			previousTools.removeValue(forKey: paneId)
			previousMessageCounts.removeValue(forKey: paneId)
			transitionMessages.removeValue(forKey: paneId)
		}
	}

	private func expireTransitions() {
		let now = Date()
		var expired: [String] = []
		for (paneId, expiry) in transitionExpiry {
			if now > expiry { expired.append(paneId) }
		}
		if !expired.isEmpty {
			withAnimation(.easeOut(duration: 0.3)) {
				for paneId in expired {
					transitionMessages.removeValue(forKey: paneId)
					transitionExpiry.removeValue(forKey: paneId)
				}
			}
		}
	}

	// MARK: - Helpers

	private func groupDotColor(_ group: ProjectGroup) -> Color {
		if group.hasBackground { return Theme.accent.opacity(0.5) }
		switch group.bestStatus {
		case .idle, .sessionStart: return Theme.textTertiary
		case .running, .runningSubagent: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed: return Theme.green
		case .sessionEnd: return Theme.textTertiary
		}
	}

	private func groupTextColor(_ group: ProjectGroup) -> Color {
		if group.hasBackground { return Theme.accent.opacity(0.6) }
		switch group.bestStatus {
		case .running, .runningSubagent: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed: return Theme.green
		default: return Theme.textTertiary
		}
	}

	private func dotColor(for companion: AgentCompanion) -> Color {
		if companion.currentTool == "Background" {
			return Theme.accent.opacity(0.5)
		}
		switch companion.status {
		case .idle, .sessionStart: return Theme.textTertiary
		case .running, .runningSubagent: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed: return Theme.green
		case .sessionEnd: return Theme.textTertiary
		}
	}

	private func statusTextColor(for companion: AgentCompanion) -> Color {
		if companion.currentTool == "Background" {
			return Theme.accent.opacity(0.6)
		}
		switch companion.status {
		case .running, .runningSubagent: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed: return Theme.green
		default: return Theme.textTertiary
		}
	}

	private func statusLabel(for companion: AgentCompanion) -> String {
		if companion.currentTool == "Background" { return "Background" }
		switch companion.status {
		case .idle, .sessionStart: return "Idle"
		case .running: return "Running"
		case .runningSubagent: return "Agent"
		case .waiting: return "Waiting"
		case .completed: return "Done"
		case .sessionEnd: return "Ended"
		}
	}

	private func transitionText(for companion: AgentCompanion) -> String {
		if companion.currentTool == "Background" {
			return "⏳ " + (companion.messages.last?.text ?? "Background")
		}
		switch companion.status {
		case .running:
			if let tool = companion.currentTool {
				return "▶ " + tool
			}
			return "▶ Running"
		case .waiting:
			let msg = companion.messages.last?.text ?? companion.userPrompt
			if !msg.isEmpty {
				let short = msg.prefix(40)
				return "⏸ " + short + (msg.count > 40 ? "…" : "")
			}
			return "⏸ Waiting"
		case .completed:
			if let last = companion.messages.last?.text, !last.isEmpty {
				let short = last.prefix(40)
				return "✓ " + short + (last.count > 40 ? "…" : "")
			}
			return "✓ Done"
		default: return ""
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
}
