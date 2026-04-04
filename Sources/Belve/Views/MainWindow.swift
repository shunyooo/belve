import SwiftUI

struct MainWindow: View {
	@State private var selectedProject: Project?
	@State private var showSidebar = true
	@EnvironmentObject var commandPaletteState: CommandPaletteState
	@State private var splitPosition: CGFloat = 500
	@State private var projects: [Project] = []

	var body: some View {
		ZStack {
			// Main layout
			HStack(spacing: 0) {
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
									.id(project.id)
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
						WelcomeView {
							addProject()
						}
					}
				}
				.background(Theme.surface)
			}

			// Command palette overlay
			if commandPaletteState.isPresented {
				Color.black.opacity(0.3)
					.ignoresSafeArea()
					.onTapGesture {
						commandPaletteState.isPresented = false
					}

				VStack {
					CommandPaletteView(
						isPresented: $commandPaletteState.isPresented,
						commands: buildCommands()
					)
					.padding(.top, 80)
					Spacer()
				}
			}
		}
		.background(Theme.bg)
		.preferredColorScheme(.dark)
		.onAppear {
			loadProjects()
		}
	}

	private func buildCommands() -> [PaletteCommand] {
		var cmds: [PaletteCommand] = []

		cmds.append(PaletteCommand(title: "New Project", icon: "plus.circle") {
			addProject()
		})

		cmds.append(PaletteCommand(title: "SSH Connect", icon: "link") {
			// TODO: SSH host selection
		})

		cmds.append(PaletteCommand(title: "Toggle Sidebar", icon: "sidebar.left") {
			showSidebar.toggle()
		})

		if selectedProject != nil {
			cmds.append(PaletteCommand(title: "Delete Project", icon: "trash") {
				deleteSelectedProject()
			})
		}

		return cmds
	}

	private func addProject() {
		let name = "Project \(projects.count + 1)"
		let project = Project(name: name)
		projects.append(project)
		selectedProject = project
		saveProjects()
	}

	private func deleteSelectedProject() {
		guard let selected = selectedProject else { return }
		projects.removeAll { $0.id == selected.id }
		selectedProject = projects.first
		saveProjects()
	}

	// MARK: - Persistence

	private static var projectsFileURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("projects.json")
	}

	private func loadProjects() {
		guard let data = try? Data(contentsOf: Self.projectsFileURL),
			  let decoded = try? JSONDecoder().decode([Project].self, from: data),
			  !decoded.isEmpty else {
			// First launch: no projects
			return
		}
		projects = decoded
		selectedProject = projects.first
	}

	private func saveProjects() {
		if let data = try? JSONEncoder().encode(projects) {
			try? data.write(to: Self.projectsFileURL)
		}
	}
}

struct WelcomeView: View {
	let onNewProject: () -> Void

	var body: some View {
		VStack(spacing: 16) {
			Text("Belve")
				.font(.system(size: 24, weight: .semibold))
				.foregroundStyle(Theme.textPrimary)

			Text("Create a project to get started")
				.font(Theme.fontBody)
				.foregroundStyle(Theme.textSecondary)

			Button {
				onNewProject()
			} label: {
				HStack(spacing: 6) {
					Image(systemName: "plus")
						.font(.system(size: 12, weight: .medium))
					Text("New Project")
						.font(.system(size: 13, weight: .medium))
				}
				.foregroundStyle(Theme.bg)
				.padding(.horizontal, 16)
				.padding(.vertical, 8)
				.background(Theme.accent)
				.cornerRadius(Theme.radiusMd)
			}
			.buttonStyle(.plain)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
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
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(isHoveringSidebar ? Theme.textPrimary : Theme.textTertiary)
			}
			.buttonStyle(.plain)
			.onHover { hovering in
				isHoveringSidebar = hovering
			}

			if let project {
				Text(project.name)
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)

				if let host = project.sshHost {
					Text("·")
						.foregroundStyle(Theme.textTertiary)
					Text(host)
						.font(.system(size: 10, weight: .regular, design: .monospaced))
						.foregroundStyle(Theme.textTertiary)
				}
			}

			Spacer()
		}
		.padding(.horizontal, 10)
		.frame(height: 22)
		.background(Theme.surface)
	}
}
