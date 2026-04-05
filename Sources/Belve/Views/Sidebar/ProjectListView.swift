import SwiftUI

struct ProjectListView: View {
	let projects: [Project]
	@Binding var selectedProject: Project?
	@EnvironmentObject var notificationStore: NotificationStore
	var onAddProject: (() -> Void)?
	var onToggleSidebar: (() -> Void)?
	var onOpenNotifications: (() -> Void)?

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Spacer().frame(height: Theme.titlebarHeight)
			ScrollView {
				VStack(spacing: 2) {
					ForEach(projects) { project in
						Button {
							selectedProject = project
						} label: {
							ProjectRow(
								project: project,
								isSelected: selectedProject == project,
								unreadCount: notificationStore.unreadCount(for: project.id),
								agentState: notificationStore.agentStatus[project.id]
							)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 8)
			}
		}
		.overlay(alignment: .topTrailing) {
			HStack(spacing: 4) {
				SidebarIconButton(icon: "plus", action: { onAddProject?() })
				ZStack(alignment: .topTrailing) {
					SidebarIconButton(icon: "bell", action: { onOpenNotifications?() })
					if notificationStore.totalUnreadCount() > 0 {
						Circle()
							.fill(Theme.red)
							.frame(width: 8, height: 8)
							.offset(x: 2, y: -2)
					}
				}
				SidebarIconButton(icon: "sidebar.left", action: { onToggleSidebar?() })
			}
			.padding(.trailing, 6)
			.padding(.top, 4)
		}
	}
}

struct SidebarIconButton: View {
	let icon: String
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: icon)
				.font(.system(size: 14, weight: .medium))
				.foregroundStyle(isHovering ? Theme.textPrimary : Theme.textTertiary)
				.frame(width: 28, height: 28)
		}
		.buttonStyle(.plain)
		.onHover { hovering in
			isHovering = hovering
		}
	}
}

struct ProjectRow: View {
	let project: Project
	let isSelected: Bool
	var unreadCount: Int = 0
	var agentState: AgentState?
	@State private var isHovering = false

	private var statusColor: Color {
		switch agentState?.status {
		case .running: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed: return Theme.green
		case .sessionStart: return Theme.accent
		default: return project.sshHost != nil ? Theme.accent : Theme.green
		}
	}

	var body: some View {
		HStack(spacing: 10) {
			Circle()
				.fill(statusColor)
				.frame(width: 7, height: 7)

			Text(project.name)
				.font(Theme.fontBody)
				.foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
				.lineLimit(1)

			Spacer()

			if unreadCount > 0 {
				Text("\(unreadCount)")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(.white)
					.padding(.horizontal, 5)
					.padding(.vertical, 1)
					.background(Theme.accent)
					.cornerRadius(6)
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
		.background(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.fill(isSelected ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
		)
		.overlay(
			HStack {
				if isSelected {
					RoundedRectangle(cornerRadius: 1)
						.fill(Theme.accent)
						.frame(width: 2, height: 16)
						.transition(.opacity.combined(with: .scale))
				}
				Spacer()
			}
		)
		.contentShape(Rectangle())
		.onHover { hovering in
			isHovering = hovering
		}
	}
}
