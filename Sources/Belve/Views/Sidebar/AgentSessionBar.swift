import SwiftUI

/// Secondary sidebar showing real-time agent session activity across all projects.
struct AgentSessionBar: View {
	let projects: [Project]
	@Binding var selectedProject: Project?
	@ObservedObject var activeCommandState: CommandAreaState
	var onFocusPane: ((UUID, String) -> Void)?
	var onToggle: (() -> Void)?
	@EnvironmentObject var notificationStore: NotificationStore
	@Namespace private var focusNamespace

	private func projectName(for id: UUID) -> String? {
		projects.first { $0.id == id }?.name
	}

	// Terminal statuses (session is effectively over) — show in Archive section.
	// - sessionEnd: Claude/Codex SessionEnd hook fired
	// - idle: app restart marked previously-running sessions as stale
	private static let terminalStatuses: Set<AgentStatus> = [.sessionEnd, .idle]

	private var activeSessions: [AgentSession] {
		notificationStore.sessions
			.filter { !$0.isArchived && !Self.terminalStatuses.contains($0.status) }
			.sorted { $0.updatedAt > $1.updatedAt }
	}

	private var archivedSessions: [AgentSession] {
		notificationStore.sessions
			.filter { $0.isArchived || Self.terminalStatuses.contains($0.status) }
			.sorted { $0.updatedAt > $1.updatedAt }
	}

	private struct ProjectGroup: Identifiable {
		let id: UUID
		let name: String
		let sessions: [AgentSession]
	}

	private func grouped(_ sessions: [AgentSession]) -> [ProjectGroup] {
		let byProject = Dictionary(grouping: sessions) { $0.projectId }
		// Preserve sidebar order; for project IDs not in `projects` (e.g. deleted projects
		// with lingering archive entries), append at the end.
		var groups: [ProjectGroup] = []
		var seen: Set<UUID> = []
		for project in projects {
			if let list = byProject[project.id], !list.isEmpty {
				groups.append(ProjectGroup(id: project.id, name: project.name, sessions: list))
				seen.insert(project.id)
			}
		}
		for (pid, list) in byProject where !seen.contains(pid) {
			groups.append(ProjectGroup(id: pid, name: projectName(for: pid) ?? "Unknown", sessions: list))
		}
		return groups
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Spacer().frame(height: Theme.titlebarHeight)

			ScrollView {
				LazyVStack(spacing: 2) {
					ForEach(grouped(activeSessions)) { group in
						projectHeader(name: group.name)
						ForEach(group.sessions) { session in
							sessionRow(session)
						}
					}

					if !archivedSessions.isEmpty {
						HStack(spacing: 6) {
							Theme.borderSubtle.frame(height: 1)
							Text("Archive")
								.font(.system(size: 9, weight: .medium))
								.foregroundStyle(Theme.textTertiary)
							Theme.borderSubtle.frame(height: 1)
						}
						.padding(.horizontal, 8)
						.padding(.vertical, 6)

						ForEach(grouped(archivedSessions)) { group in
							projectHeader(name: group.name)
								.opacity(0.6)
							ForEach(group.sessions) { session in
								sessionRow(session)
									.opacity(0.5)
							}
						}
					}
				}
				.padding(.horizontal, 4)
				.padding(.top, 4)
			}
		}
		.overlay(alignment: .topLeading) {
			if let onToggle {
				SidebarIconButton(icon: "list.bullet.rectangle.fill", action: onToggle)
					.padding(.leading, 6)
					.padding(.top, 4)
			}
		}
		.animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.18), value: activeCommandState.activePaneId)
		.onReceive(NotificationCenter.default.publisher(for: .belvePaneClosed)) { notif in
			if let paneId = notif.userInfo?["paneId"] as? String {
				notificationStore.archiveSessionsForPane(paneId)
			}
		}
	}

	private func projectHeader(name: String) -> some View {
		HStack(spacing: 6) {
			Image(systemName: "folder.fill")
				.font(.system(size: 9))
				.foregroundStyle(Theme.accent.opacity(0.8))
			Text(name)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(Theme.textPrimary)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 12)
		.padding(.top, 8)
		.padding(.bottom, 4)
	}

	private func sessionRow(_ session: AgentSession) -> some View {
		SessionRow(
			session: session,
			projectName: nil,  // shown in the group header now
			isFocused: !session.isArchived && session.paneId.flatMap { UUID(uuidString: $0) } == activeCommandState.activePaneId,
			focusNamespace: focusNamespace
		)
		.onTapGesture {
			if let project = projects.first(where: { $0.id == session.projectId }) {
				selectedProject = project
			}
			if !session.isArchived, let paneId = session.paneId {
				onFocusPane?(session.projectId, paneId)
			}
		}
	}
}

// MARK: - Session Row

private struct SessionRow: View {
	let session: AgentSession
	let projectName: String?
	var isFocused: Bool = false
	var focusNamespace: Namespace.ID?
	@State private var isHovering = false

	private var statusColor: Color {
		switch session.status {
		case .running: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed, .sessionEnd: return Theme.green
		case .sessionStart: return Theme.accent
		case .idle: return Theme.textTertiary
		}
	}

	private var isActive: Bool {
		session.status == .running || session.status == .waiting || session.status == .sessionStart
	}

	private var isVisible: Bool {
		isActive || session.status == .completed
	}

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			VStack {
				Spacer().frame(height: 3)
				if isActive {
					PulsingDot(color: statusColor)
				} else if session.status == .completed {
					Circle()
						.fill(statusColor)
						.frame(width: 7, height: 7)
						.frame(width: 12, height: 12)
				} else {
					Circle()
						.fill(statusColor.opacity(0.3))
						.frame(width: 7, height: 7)
						.frame(width: 12, height: 12)
				}
			}

			VStack(alignment: .leading, spacing: 3) {
				// Latest user prompt (fallback to session label)
				Text(session.lastUserPrompt ?? session.label ?? session.message)
					.font(.system(size: 12, weight: isVisible ? .medium : .regular))
					.foregroundStyle(isVisible ? Theme.textPrimary : Theme.textTertiary)
					.lineLimit(2)

				// Current activity detail
				if isVisible {
					VStack(alignment: .leading, spacing: 1) {
						if let tool = session.currentTool {
							HStack(spacing: 3) {
								Image(systemName: "wrench.and.screwdriver")
									.font(.system(size: 9))
								Text(tool)
									.lineLimit(1)
							}
							.font(.system(size: 10))
							.foregroundStyle(Theme.accent)

							if let detail = session.lastAgentActivity, !detail.isEmpty {
								Text(detail)
									.font(.system(size: 9))
									.foregroundStyle(Theme.textTertiary)
									.lineLimit(3)
							}
						} else if session.status == .waiting {
							Text(session.message)
								.font(.system(size: 10))
								.foregroundStyle(Theme.yellow)
								.lineLimit(4)
						} else if session.status == .completed {
							if let activity = session.lastAgentActivity {
								Text(activity)
									.font(.system(size: 10))
									.foregroundStyle(Theme.textSecondary)
									.lineLimit(4)
							}
							Text("Done")
								.font(.system(size: 9))
								.foregroundStyle(Theme.green)
						} else {
							Text("Thinking...")
								.font(.system(size: 10))
								.foregroundStyle(Theme.textTertiary)
						}
					}
					.animation(nil, value: session.currentTool)
				}

				// Project + time
				HStack(spacing: 4) {
					if let name = projectName {
						Text(name)
							.font(.system(size: 10))
							.foregroundStyle(Theme.textTertiary)
					}
					Text(session.updatedAt.relativeString)
						.font(.system(size: 10))
						.foregroundStyle(Theme.textTertiary.opacity(0.6))
				}
			}

			Spacer(minLength: 0)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
		.background(
			ZStack {
				if !isFocused && isVisible {
					RoundedRectangle(cornerRadius: 4)
						.fill(Theme.surfaceActive.opacity(0.3))
				} else if !isFocused && isHovering {
					RoundedRectangle(cornerRadius: 4)
						.fill(Theme.surfaceHover)
				}
				if isFocused {
					if let ns = focusNamespace {
						RoundedRectangle(cornerRadius: 4)
							.fill(Theme.surfaceActive)
							.matchedGeometryEffect(id: "sessionFocusBackground", in: ns)
					} else {
						RoundedRectangle(cornerRadius: 4)
							.fill(Theme.surfaceActive)
					}
				}
			}
		)
		.overlay(
			HStack {
				if isFocused {
					if let ns = focusNamespace {
						RoundedRectangle(cornerRadius: 1)
							.fill(Theme.accent)
							.frame(width: 2, height: 14)
							.matchedGeometryEffect(id: "sessionFocusBar", in: ns)
					} else {
						RoundedRectangle(cornerRadius: 1)
							.fill(Theme.accent)
							.frame(width: 2, height: 14)
					}
				}
				Spacer()
			}
			.padding(.leading, 6)
		)
		.padding(.horizontal, 4)
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}
}

// MARK: - Pulsing Dot

private struct PulsingDot: View {
	let color: Color
	@State private var isPulsing = false

	var body: some View {
		Circle()
			.fill(color)
			.frame(width: 7, height: 7)
			.overlay(
				Circle()
					.stroke(color.opacity(0.4), lineWidth: 1.5)
					.frame(width: 12, height: 12)
					.scaleEffect(isPulsing ? 1.3 : 1.0)
					.opacity(isPulsing ? 0 : 0.6)
			)
			.frame(width: 12, height: 12)
			.onAppear {
				withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
					isPulsing = true
				}
			}
	}
}

// MARK: - Date Extension

private extension Date {
	var relativeString: String {
		let interval = -timeIntervalSinceNow
		if interval < 60 { return "now" }
		if interval < 3600 { return "\(Int(interval / 60))m" }
		if interval < 86400 { return "\(Int(interval / 3600))h" }
		return "\(Int(interval / 86400))d"
	}
}
