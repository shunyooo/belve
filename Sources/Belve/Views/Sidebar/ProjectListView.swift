import SwiftUI

struct ProjectListView: View {
	let projects: [Project]
	@Binding var selectedProject: Project?

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Section label (with traffic light clearance)
			Text("PROJECTS")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(Theme.textTertiary)
				.tracking(1.2)
				.padding(.horizontal, 16)
				.padding(.top, 12)
				.padding(.bottom, 6)

			// Project list
			VStack(spacing: 2) {
				ForEach(projects) { project in
					ProjectRow(
						project: project,
						isSelected: selectedProject == project
					)
					.onTapGesture {
						withAnimation(.easeInOut(duration: 0.15)) {
							selectedProject = project
						}
					}
				}
			}
			.padding(.horizontal, 8)

			Spacer()

			// Bottom status
			HStack(spacing: 6) {
				Circle()
					.fill(Theme.green)
					.frame(width: 6, height: 6)
				Text("Connected")
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(Theme.textTertiary)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
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
			withAnimation(.easeInOut(duration: 0.12)) {
				isHovering = hovering
			}
		}
	}
}
