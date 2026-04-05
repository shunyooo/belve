import SwiftUI

struct MainWindow: View {
	@State private var selectedProject: Project?
	@State private var showSidebar = true
	@EnvironmentObject var commandPaletteState: CommandPaletteState
	@State private var splitPosition: CGFloat = 500
	@State private var projects: [Project] = []
	@State private var openFile: OpenFile?
	@State private var paletteMode: PaletteMode = .commands
	@StateObject private var commandAreaState = CommandAreaState()

	enum PaletteMode {
		case commands
		case sshHosts
		case folderBrowser
	}
	@State private var browserPath: String = ""

	var body: some View {
		ZStack {
			// Main layout
			HStack(spacing: 0) {
				ProjectListView(
						projects: projects,
						selectedProject: $selectedProject,
						onAddProject: { addProject() },
						onToggleSidebar: { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } },
						onOpenNotifications: { /* TODO: notification panel */ }
					)
					.frame(width: showSidebar ? Theme.sidebarWidth : 0)
					.clipped()
					.background(Theme.bg)

					if showSidebar {
						Theme.border
							.frame(width: 1)
					}

				VStack(spacing: 0) {
					TopBar(
						project: selectedProject,
						showSidebar: $showSidebar
					)

					if let project = selectedProject {
						GeometryReader { geo in
							HStack(spacing: 0) {
								CommandArea(project: project, state: commandAreaState)
									.id(project.id)
									.frame(width: splitPosition)
									.environmentObject(commandAreaState)

								SplitDivider(
									position: $splitPosition,
									minLeft: 250,
									minRight: 250
								)

								PreviewArea(project: project, openFile: $openFile)
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
					if paletteMode == .folderBrowser {
						FolderBrowserView(
							isPresented: $commandPaletteState.isPresented,
							initialPath: browserPath,
							sshHost: selectedProject?.sshHost
						) { path in
							setProjectFolder(path)
						}
						.padding(.top, 80)
					} else {
						CommandPaletteView(
							isPresented: $commandPaletteState.isPresented,
							commands: buildPaletteCommands()
						)
						.padding(.top, 80)
					}
					Spacer()
				}
				.onChange(of: commandPaletteState.isPresented) {
					if !commandPaletteState.isPresented {
						paletteMode = .commands
					}
				}
			}
		}
		.background(Theme.bg)
		.preferredColorScheme(.dark)
		.onAppear {
			loadProjects()
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveSplitVertical)) { _ in
			commandAreaState.splitActive(.vertical)
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveSplitHorizontal)) { _ in
			commandAreaState.splitActive(.horizontal)
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveSwitchProject)) { notification in
			if let index = notification.userInfo?["index"] as? Int,
			   index >= 0, index < projects.count {
				selectedProject = projects[index]
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveFocusProject)) { notification in
			if let projectId = notification.userInfo?["projectId"] as? UUID,
			   let project = projects.first(where: { $0.id == projectId }) {
				selectedProject = project
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveOpenFolder)) { _ in
			if commandPaletteState.isPresented && paletteMode == .folderBrowser {
				commandPaletteState.isPresented = false
			} else {
				openFolder()
			}
		}
	}

	private func buildPaletteCommands() -> [PaletteCommand] {
		switch paletteMode {
		case .commands:
			return buildMainCommands()
		case .sshHosts:
			return buildSSHHostCommands()
		case .folderBrowser:
			return [] // handled by FolderBrowserView
		}
	}

	private func buildMainCommands() -> [PaletteCommand] {
		var cmds: [PaletteCommand] = []

		cmds.append(PaletteCommand(title: "New Project", icon: "plus.circle") {
			addProject()
		})

		cmds.append(PaletteCommand(title: "SSH Connect", icon: "link") {
			paletteMode = .sshHosts
			commandPaletteState.isPresented = true
		})

		if selectedProject?.sshHost != nil {
			cmds.append(PaletteCommand(title: "Open DevContainer", icon: "shippingbox") {
				openDevContainer()
			})
		}

		cmds.append(PaletteCommand(title: "Split Terminal Vertical", icon: "rectangle.split.1x2") {
			commandAreaState.splitActive(.vertical)
		})

		cmds.append(PaletteCommand(title: "Split Terminal Horizontal", icon: "rectangle.split.2x1") {
			commandAreaState.splitActive(.horizontal)
		})

		cmds.append(PaletteCommand(title: "Toggle Sidebar", icon: "sidebar.left") {
			withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
		})

		if selectedProject != nil {
			cmds.append(PaletteCommand(title: "Delete Project", icon: "trash") {
				deleteSelectedProject()
			})
		}

		return cmds
	}

	private func buildSSHHostCommands() -> [PaletteCommand] {
		let hosts = SSHConfigParser.parse()
		return hosts.map { host in
			let subtitle = [host.user, host.hostname].compactMap { $0 }.joined(separator: "@")
			return PaletteCommand(
				title: "\(host.name)" + (subtitle.isEmpty ? "" : " (\(subtitle))"),
				icon: "network"
			) {
				connectSSH(host: host.name)
			}
		}
	}

	private func openDevContainer() {
		guard let index = projects.firstIndex(where: { $0.id == selectedProject?.id }),
			  let sshHost = projects[index].sshHost else { return }
		// Use remotePath or home directory as workspace
		let workspacePath = projects[index].remotePath ?? "~"
		projects[index].devContainerPath = workspacePath

		// Recreate terminal
		let project = projects[index]
		selectedProject = nil
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			selectedProject = project
			saveProjects()
		}
		NSLog("[Belve] DevContainer enabled for \(project.name) at \(sshHost):\(workspacePath)")
	}

	private func openFolder() {
		browserPath = selectedProject?.remotePath ?? NSHomeDirectory()
		paletteMode = .folderBrowser
		commandPaletteState.isPresented = true
	}

	private func setProjectFolder(_ path: String) {
		guard let index = projects.firstIndex(where: { $0.id == selectedProject?.id }) else { return }
		projects[index].remotePath = path
		projects[index].name = (path as NSString).lastPathComponent
		let project = projects[index]
		selectedProject = nil
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			selectedProject = project
			saveProjects()
		}
		NSLog("[Belve] Opened folder: \(path)")
	}

	private func addProject() {
		let name = "Project \(projects.count + 1)"
		let project = Project(name: name)
		projects.append(project)
		selectedProject = project
		saveProjects()
	}

	private func connectSSH(host: String) {
		guard let index = projects.firstIndex(where: { $0.id == selectedProject?.id }) else {
			// No project selected, create one
			let project = Project(name: host, sshHost: host)
			projects.append(project)
			selectedProject = project
			saveProjects()
			return
		}
		projects[index].sshHost = host
		// Force terminal recreation by updating selectedProject
		let project = projects[index]
		selectedProject = nil
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			selectedProject = project
			saveProjects()
		}
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
	@EnvironmentObject var notificationStore: NotificationStore
	@State private var isHoveringSidebar = false

	var body: some View {
		HStack(spacing: 8) {
			// Show toggle only when sidebar is hidden
			if !showSidebar {
				Button {
					withAnimation(.easeInOut(duration: 0.2)) { showSidebar = true }
				} label: {
					Image(systemName: "sidebar.left")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(isHoveringSidebar ? Theme.textPrimary : Theme.textTertiary)
				}
				.buttonStyle(.plain)
				.onHover { hovering in
					isHoveringSidebar = hovering
				}
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

				if let label = notificationStore.sessionLabels[project.id] {
					Text("·")
						.foregroundStyle(Theme.textTertiary)
					Text(label)
						.font(.system(size: 10, weight: .regular))
						.foregroundStyle(Theme.textTertiary)
						.lineLimit(1)
				}
			}

			Spacer()
		}
		.padding(.horizontal, 12)
		.frame(height: Theme.titlebarHeight)
		.background(Theme.bg)
	}
}
