import SwiftUI

struct MainWindow: View {
	@State private var selectedProject: Project?
	@State private var showSidebar = true
	@State private var splitPosition: CGFloat = 500
	@State private var projects: [Project] = [
		Project(name: "Local Shell"),
		Project(name: "clay-api-flamel", sshHost: "kawamoto-clay-dev-v2"),
		Project(name: "clay-app-playground", sshHost: "kawamoto-clay-dev-v2"),
	]

	var body: some View {
		HStack(spacing: 0) {
			// Sidebar
			if showSidebar {
				ProjectListView(
					projects: projects,
					selectedProject: $selectedProject
				)
				.frame(width: 200)
				.background(Theme.bg)

				Theme.border
					.frame(width: 1)
			}

			// Main content
			VStack(spacing: 0) {
				TopBar(
					project: selectedProject,
					showSidebar: $showSidebar
				)

				Theme.borderSubtle
					.frame(height: 1)

				if let project = selectedProject {
					GeometryReader { geo in
						HStack(spacing: 0) {
							CommandArea(project: project)
								.frame(width: splitPosition)

							SplitDivider(
								position: $splitPosition,
								minLeft: 250,
								minRight: 250
							)

							PreviewArea(project: project)
								.frame(maxWidth: .infinity)
						}
						.onAppear {
							splitPosition = geo.size.width * 0.5
						}
					}
				} else {
					VStack(spacing: 8) {
						Image(systemName: "arrow.left.circle")
							.font(.system(size: 28, weight: .thin))
							.foregroundStyle(Theme.textTertiary)
						Text("Select a project")
							.font(Theme.fontBody)
							.foregroundStyle(Theme.textTertiary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.background(Theme.surface)
		}
		.background(Theme.bg)
		.preferredColorScheme(.dark)
		.onAppear {
			selectedProject = projects.first
		}
	}
}

struct TopBar: View {
	let project: Project?
	@Binding var showSidebar: Bool
	@State private var isHoveringSidebar = false

	var body: some View {
		HStack(spacing: 8) {
			Button {
				showSidebar.toggle()
			} label: {
				Image(systemName: "sidebar.left")
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(isHoveringSidebar ? Theme.textPrimary : Theme.textTertiary)
			}
			.buttonStyle(.plain)
			.onHover { hovering in
				isHoveringSidebar = hovering
			}

			if let project {
				Text(project.name)
					.font(Theme.fontHeading)
					.foregroundStyle(Theme.textPrimary)

				if let host = project.sshHost {
					Text("·")
						.foregroundStyle(Theme.textTertiary)
					Text(host)
						.font(.system(size: 11, weight: .regular, design: .monospaced))
						.foregroundStyle(Theme.textTertiary)
				}
			}

			Spacer()
		}
		.padding(.horizontal, 12)
		.frame(height: 28)
		.background(Theme.surface)
	}
}
