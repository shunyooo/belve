import SwiftUI

struct MainWindow: View {
	@EnvironmentObject var commandPaletteState: CommandPaletteState
	@EnvironmentObject var projectStore: ProjectStore
	@State private var showSidebar = true
	@State private var splitPosition: CGFloat = 500
	@State private var openFile: OpenFile?
	@State private var paletteMode: PaletteMode = .commands
	@StateObject private var commandAreaState = CommandAreaState()
	@State private var browserPath: String = ""

	enum PaletteMode {
		case commands
		case sshHosts
		case folderBrowser
	}

	var body: some View {
		ZStack {
			HStack(spacing: 0) {
				// Sidebar
				if showSidebar {
					ProjectListView(
						projects: projectStore.projects,
						selectedProject: Binding(
							get: { projectStore.selectedProject },
							set: { projectStore.select($0) }
						),
						onAddProject: { let _ = projectStore.addProject() },
						onToggleSidebar: { withAnimation(.easeOut(duration: 0.15)) { showSidebar.toggle() } },
						onOpenNotifications: {},
						onRenameProject: { id, name in projectStore.renameProject(id, name: name) },
						onDeleteProject: { id in projectStore.deleteProject(id) }
					)
					.frame(width: Theme.sidebarWidth)
					Theme.borderSubtle
						.frame(width: 1)
				}

				// Main content
				VStack(spacing: 0) {
					// Top bar
					TopBar(
						projectName: projectStore.selectedProject?.name ?? "",
						showSidebar: showSidebar,
						onToggleSidebar: { withAnimation(.easeOut(duration: 0.15)) { showSidebar.toggle() } },
						sessionLabel: nil
					)
					Theme.borderSubtle
						.frame(height: 1)

					// Content
					if !projectStore.projects.isEmpty {
						GeometryReader { geo in
							ZStack {
								ForEach(projectStore.projects) { project in
									let isSelected = project.id == projectStore.selectedProject?.id
									ZStack(alignment: .bottomTrailing) {
										HStack(spacing: 0) {
											CommandArea(project: project, state: commandAreaState)
												.frame(width: splitPosition)
												.environmentObject(commandAreaState)

											SplitDivider(
												position: $splitPosition,
												minLeft: 250,
												minRight: 250
											)

											PreviewArea(project: project, openFile: isSelected ? $openFile : .constant(nil))
												.id(project.hashValue)  // Rebuild when project properties change
												.frame(maxWidth: .infinity)
										}

										if isSelected && projectStore.showDevContainerBanner && !project.isDevContainer {
											DevContainerBanner(
												onReopen: {
													projectStore.showDevContainerBanner = false
													projectStore.openDevContainer()
												},
												onDismiss: {
													projectStore.showDevContainerBanner = false
												}
											)
											.padding(.bottom, 16)
											.padding(.trailing, 16)
											.transition(.move(edge: .bottom).combined(with: .opacity))
										}
									}
									.opacity(isSelected ? 1 : 0)
									.allowsHitTesting(isSelected)
								}
							}
							.onAppear {
								splitPosition = geo.size.width * 0.5
							}
						}
					} else {
						WelcomeView {
							let _ = projectStore.addProject()
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
							executionContext: projectStore.selectedProject?.executionContext ?? .local
						) { path in
							projectStore.setProjectFolder(path)
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
			}
		}
		.background(Theme.bg)
		.onKeyPress(characters: .init(charactersIn: "123456789"), phases: .down) { press in
			guard press.modifiers == .command else { return .ignored }
			if let digit = press.characters.first, let index = digit.wholeNumberValue {
				projectStore.selectByIndex(index - 1)
				return .handled
			}
			return .ignored
		}
		.onChange(of: projectStore.selectedProject) {
			openFile = nil
		}
		.onChange(of: commandPaletteState.isPresented) {
			if !commandPaletteState.isPresented {
				paletteMode = .commands
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveCommandPalette)) { _ in
			paletteMode = .commands
			commandPaletteState.isPresented.toggle()
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveFocusProject)) { notif in
			if let projectId = notif.userInfo?["projectId"] as? UUID,
			   let project = projectStore.projects.first(where: { $0.id == projectId }) {
				DispatchQueue.main.async { [self] in projectStore.select(project) }
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveNewProject)) { _ in
			DispatchQueue.main.async { [self] in let _ = projectStore.addProject() }
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveReloadProject)) { _ in
			DispatchQueue.main.async { [self] in projectStore.reloadCurrentProject() }
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveOpenFolder)) { _ in
			if commandPaletteState.isPresented && paletteMode == .folderBrowser {
				commandPaletteState.isPresented = false
			} else {
				openFolder()
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveSplitVertical)) { _ in
			commandAreaState.splitActive(.vertical)
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveSplitHorizontal)) { _ in
			commandAreaState.splitActive(.horizontal)
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveClosePane)) { _ in
			commandAreaState.closeActivePane()
		}
	}

	// MARK: - Command Palette

	private func buildPaletteCommands() -> [PaletteCommand] {
		switch paletteMode {
		case .commands:
			return buildMainCommands()
		case .sshHosts:
			return buildSSHHostCommands()
		case .folderBrowser:
			return []
		}
	}

	private func buildMainCommands() -> [PaletteCommand] {
		var cmds: [PaletteCommand] = []

		cmds.append(PaletteCommand(title: "Open Folder", icon: "folder") {
			openFolder()
		})

		cmds.append(PaletteCommand(title: "SSH Connect", icon: "link") {
			paletteMode = .sshHosts
			commandPaletteState.isPresented = true
		})

		if let project = projectStore.selectedProject, project.sshHost != nil {
			if project.isDevContainer {
				cmds.append(PaletteCommand(title: "Reopen without Container (SSH)", icon: "arrow.uturn.backward") {
					projectStore.closeDevContainer()
				})
			} else {
				cmds.append(PaletteCommand(title: "Reopen in Container", icon: "shippingbox") {
					projectStore.openDevContainer()
				})
			}
			cmds.append(PaletteCommand(title: "Disconnect SSH (Local)", icon: "wifi.slash") {
				projectStore.disconnectSSH()
			})
		}

		cmds.append(PaletteCommand(title: "Split Terminal Vertical", icon: "rectangle.split.1x2") {
			commandAreaState.splitActive(.vertical)
		})
		cmds.append(PaletteCommand(title: "Split Terminal Horizontal", icon: "rectangle.split.2x1") {
			commandAreaState.splitActive(.horizontal)
		})
		cmds.append(PaletteCommand(title: "Toggle Sidebar", icon: "sidebar.left") {
			withAnimation(.easeOut(duration: 0.15)) { showSidebar.toggle() }
		})
		cmds.append(PaletteCommand(title: "New Project", icon: "plus") {
			let _ = projectStore.addProject()
		})
		cmds.append(PaletteCommand(title: "Delete Project", icon: "trash") {
			if let id = projectStore.selectedProject?.id {
				projectStore.deleteProject(id)
			}
		})

		return cmds
	}

	private func buildSSHHostCommands() -> [PaletteCommand] {
		SSHConfigParser.parse().map { host in
			PaletteCommand(title: host.name, icon: "network") {
				projectStore.connectSSH(host: host.name)
			}
		}
	}

	// MARK: - Folder Browser

	private func openFolder() {
		browserPath = projectStore.selectedProject?.effectivePath ?? NSHomeDirectory()
		paletteMode = .folderBrowser
		commandPaletteState.isPresented = true
	}
}

// MARK: - Top Bar

struct TopBar: View {
	let projectName: String
	let showSidebar: Bool
	let onToggleSidebar: () -> Void
	var sessionLabel: String?
	@State private var isHoveringSidebar = false

	var body: some View {
		HStack(spacing: 8) {
			if !showSidebar {
				Button(action: onToggleSidebar) {
					Image(systemName: "sidebar.left")
						.font(.system(size: 13))
						.foregroundStyle(isHoveringSidebar ? Theme.textPrimary : Theme.textTertiary)
				}
				.buttonStyle(.plain)
				.onHover { isHoveringSidebar = $0 }
			}

			Spacer()

			Text(projectName)
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(Theme.textSecondary)

			if let label = sessionLabel {
				Text("— \(label)")
					.font(.system(size: 12))
					.foregroundStyle(Theme.textTertiary)
					.lineLimit(1)
			}

			Spacer()
		}
		.padding(.horizontal, showSidebar ? 12 : 80)
		.frame(height: Theme.titlebarHeight)
		.background(Theme.bg)
	}
}

// MARK: - Welcome View

struct WelcomeView: View {
	let onCreateProject: () -> Void

	var body: some View {
		VStack(spacing: 12) {
			Image(systemName: "rectangle.stack")
				.font(.system(size: 40, weight: .ultraLight))
				.foregroundStyle(Theme.textTertiary)
			Text("Create a project to get started")
				.font(Theme.fontBody)
				.foregroundStyle(Theme.textTertiary)
			Button(action: onCreateProject) {
				Text("New Project")
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(.white)
					.padding(.horizontal, 16)
					.padding(.vertical, 6)
					.background(
						RoundedRectangle(cornerRadius: 6)
							.fill(Theme.accent)
					)
			}
			.buttonStyle(.plain)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Theme.surface)
	}
}
