import SwiftUI

/// Secondary sidebar showing real-time agent session activity across all projects.
struct AgentSessionBar: View {
	let projects: [Project]
	@Binding var selectedProject: Project?
	@ObservedObject var activeCommandState: CommandAreaState
	var onFocusPane: ((UUID, String) -> Void)?
	@EnvironmentObject var notificationStore: NotificationStore

	private func projectName(for id: UUID) -> String? {
		projects.first { $0.id == id }?.name
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Spacer().frame(height: Theme.titlebarHeight)

			ScrollView {
				LazyVStack(spacing: 2) {
					ForEach(notificationStore.sessions) { session in
						SessionRow(
							session: session,
							projectName: projectName(for: session.projectId),
							isFocused: session.paneId.flatMap { UUID(uuidString: $0) } == activeCommandState.activePaneId
						)
						.onTapGesture {
							if let project = projects.first(where: { $0.id == session.projectId }) {
								selectedProject = project
							}
							if let paneId = session.paneId {
								onFocusPane?(session.projectId, paneId)
							}
						}
					}
				}
				.padding(.horizontal, 4)
				.padding(.top, 4)
			}
		}
	}
}

// MARK: - Session Row

private struct SessionRow: View {
	let session: AgentSession
	let projectName: String?
	var isFocused: Bool = false
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
		session.status == .running || session.status == .waiting || session.status == .sessionStart || session.status == .completed
	}

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			VStack {
				Spacer().frame(height: 3)
				if isActive {
					PulsingDot(color: statusColor)
				} else {
					Circle()
						.fill(statusColor.opacity(session.status == .sessionEnd ? 0.6 : 0.3))
						.frame(width: 7, height: 7)
						.frame(width: 12, height: 12)
				}
			}

			VStack(alignment: .leading, spacing: 3) {
				// Latest user prompt (fallback to session label)
				Text(session.lastUserPrompt ?? session.label ?? session.message)
					.font(.system(size: 12, weight: isActive ? .medium : .regular))
					.foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
					.lineLimit(2)

				// Current activity detail
				if isActive {
					if let tool = session.currentTool {
						HStack(spacing: 3) {
							Image(systemName: "wrench.and.screwdriver")
								.font(.system(size: 9))
							Text(tool)
								.lineLimit(1)
						}
						.font(.system(size: 10))
						.foregroundStyle(Theme.accent)
					} else if session.status == .waiting {
						Text(session.message)
							.font(.system(size: 10))
							.foregroundStyle(Theme.yellow)
							.lineLimit(1)
					} else if session.status == .completed {
						Text("Done")
							.font(.system(size: 10))
							.foregroundStyle(Theme.green)
					}
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
			RoundedRectangle(cornerRadius: 4)
				.fill(isFocused ? Theme.surfaceActive : (isActive ? Theme.surfaceActive.opacity(0.3) : (isHovering ? Theme.surfaceHover : Color.clear)))
		)
		.overlay(
			HStack {
				if isFocused {
					RoundedRectangle(cornerRadius: 1)
						.fill(Theme.accent)
						.frame(width: 2, height: 14)
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
