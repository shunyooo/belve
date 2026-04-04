import SwiftUI

struct ProjectListView: View {
	let projects: [Project]
	@Binding var selectedProject: Project?
	var onAddProject: (() -> Void)?
	var onToggleSidebar: (() -> Void)?
	var onOpenNotifications: (() -> Void)?

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Top bar: aligned with traffic lights (same row)
			HStack(spacing: 4) {
				Spacer()
					.frame(width: 68) // space for traffic lights (●●● ~60px + gap)
				SidebarIconButton(icon: "plus", action: { onAddProject?() })
				SidebarIconButton(icon: "bell", action: { onOpenNotifications?() })
				SidebarIconButton(icon: "sidebar.left", action: { onToggleSidebar?() })
				Spacer()
			}
			.frame(height: 20)
			.padding(.top, 3) // align vertically with traffic lights

			// Project list
			ScrollView {
				VStack(spacing: 2) {
					ForEach(projects) { project in
						Button {
							selectedProject = project
						} label: {
							ProjectRow(
								project: project,
								isSelected: selectedProject == project
							)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 8)
			}
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
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(isHovering ? Theme.textPrimary : Theme.textTertiary)
				.frame(width: 22, height: 22)
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
	@State private var isHovering = false

	var body: some View {
		HStack(spacing: 10) {
			Circle()
				.fill(project.sshHost != nil ? Theme.accent : Theme.green)
				.frame(width: 7, height: 7)

			Text(project.name)
				.font(Theme.fontBody)
				.foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
				.lineLimit(1)

			Spacer()
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
