import SwiftUI
import AppKit

struct MainWindow: View {
	@EnvironmentObject var commandPaletteState: CommandPaletteState
	@EnvironmentObject var projectStore: ProjectStore
	@State private var sidebarWidthAtDragStart: CGFloat = 0
	@State private var openFile: OpenFile?
	@State private var paletteMode: PaletteMode = .commands
	@StateObject private var stateManager = CommandAreaStateManager()
	@StateObject private var layoutState = WorkspaceLayoutStateManager()
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
				if layoutState.showSidebar {
					ProjectListView(
						projects: projectStore.projects,
						selectedProject: Binding(
							get: { projectStore.selectedProject },
							set: { projectStore.select($0) }
						),
						onAddProject: { let _ = projectStore.addProject() },
						onToggleSidebar: { withAnimation(.easeOut(duration: 0.15)) { layoutState.showSidebar.toggle() } },
						onOpenNotifications: {},
						onRenameProject: { id, name in projectStore.renameProject(id, name: name) },
						onDeleteProject: { id in projectStore.deleteProject(id) }
					)
					.frame(width: layoutState.sidebarWidth)
					Rectangle()
						.fill(Theme.borderSubtle)
						.frame(width: 1)
						.contentShape(Rectangle().inset(by: -3))
						.onHover { hovering in
							if hovering {
								NSCursor.resizeLeftRight.push()
							} else {
								NSCursor.pop()
							}
						}
						.gesture(
							DragGesture(minimumDistance: 1, coordinateSpace: .global)
								.onChanged { value in
									if sidebarWidthAtDragStart == 0 {
										sidebarWidthAtDragStart = layoutState.sidebarWidth
									}
									layoutState.sidebarWidth = max(140, min(350, sidebarWidthAtDragStart + value.translation.width))
								}
								.onEnded { _ in
									sidebarWidthAtDragStart = layoutState.sidebarWidth
								}
						)
				}

				// Main content
				VStack(spacing: 0) {
					// Top bar
					TopBar(
						projectName: projectStore.selectedProject?.name ?? "",
						connectionInfo: projectStore.selectedProject.map { Self.connectionInfo(for: $0) } ?? nil,
						showSidebar: layoutState.showSidebar,
						onToggleSidebar: { withAnimation(.easeOut(duration: 0.15)) { layoutState.showSidebar.toggle() } },
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
									let state = commandAreaState(for: project.id)
									let projectLayout = layoutState.state(for: project.id)
									let splitBinding = Binding<CGFloat>(
										get: {
											let preferred = projectLayout.commandAreaFraction * geo.size.width
											return min(max(250, preferred), max(250, geo.size.width - 250))
										},
										set: { newValue in
											let clamped = min(max(250, newValue), max(250, geo.size.width - 250))
											projectLayout.commandAreaFraction = clamped / max(geo.size.width, 1)
										}
									)
									let clampedSplit = splitBinding.wrappedValue
									ZStack(alignment: .bottomTrailing) {
										HStack(spacing: 0) {
											CommandArea(project: project, state: state)
												.frame(width: clampedSplit)
												.environmentObject(state)

											SplitDivider(
												position: splitBinding,
												minLeft: 250,
												minRight: 250,
												availableWidth: geo.size.width
											)
											.frame(width: DividerMetrics.absoluteHitWidth)

											PreviewArea(
												project: project,
												layoutState: projectLayout,
												openFile: isSelected ? $openFile : .constant(nil)
											)
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
		.background(WindowFrameAutosave(name: "BelveMainWindow"))
		// Cmd+D/W/1-9 shortcuts are handled via JS postMessage → Coordinator
		// (WKWebView consumes key events before SwiftUI .onKeyPress sees them)
		.onAppear {
			sidebarWidthAtDragStart = layoutState.sidebarWidth
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveSwitchProject)) { notif in
			if let index = notif.userInfo?["index"] as? Int {
				projectStore.selectByIndex(index)
			}
		}
		.onChange(of: projectStore.selectedProject) {
			openFile = nil
			// Refocus terminal after project switch
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				projectStore.refocusTerminal()
			}
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
		// Split/close handled via .onKeyPress above
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
			if let id = projectStore.selectedProject?.id {
				commandAreaState(for: id).splitActive(.vertical)
			}
		})
		cmds.append(PaletteCommand(title: "Split Terminal Horizontal", icon: "rectangle.split.2x1") {
			if let id = projectStore.selectedProject?.id {
				commandAreaState(for: id).splitActive(.horizontal)
			}
		})
		cmds.append(PaletteCommand(title: "Toggle Sidebar", icon: "sidebar.left") {
			withAnimation(.easeOut(duration: 0.15)) { layoutState.showSidebar.toggle() }
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

	private static func connectionInfo(for project: Project) -> String? {
		switch project.executionContext {
		case .local: return nil
		case .ssh(let host):
			let short = host.components(separatedBy: ".").first ?? host
			return "SSH: \(short)"
		case .devContainer(_, _):
			let label = project.containerImageName.map { ($0 as NSString).lastPathComponent } ?? "container"
			return "DevContainer: \(label)"
		}
	}

	private func commandAreaState(for projectId: UUID) -> CommandAreaState {
		stateManager.state(for: projectId)
	}

	private func openFolder() {
		browserPath = projectStore.selectedProject?.effectivePath ?? NSHomeDirectory()
		paletteMode = .folderBrowser
		commandPaletteState.isPresented = true
	}
}

// MARK: - Top Bar

struct TopBar: View {
	let projectName: String
	let connectionInfo: String?  // e.g. "SSH: host", "DevContainer: host", nil for local
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

			if let info = connectionInfo {
				ConnectionBadge(text: info)
			}

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

struct ConnectionBadge: View {
	let text: String

	private var icon: String {
		if text.hasPrefix("DevContainer") { return "shippingbox" }
		if text.hasPrefix("SSH") { return "network" }
		return "desktopcomputer"
	}

	private var color: Color {
		if text.hasPrefix("DevContainer") { return Theme.yellow }
		if text.hasPrefix("SSH") { return Theme.accent }
		return Theme.green
	}

	var body: some View {
		HStack(spacing: 4) {
			Image(systemName: icon)
				.font(.system(size: 9))
			Text(text)
				.font(.system(size: 10, weight: .medium))
		}
		.foregroundStyle(color)
		.padding(.horizontal, 6)
		.padding(.vertical, 2)
		.background(
			RoundedRectangle(cornerRadius: 4)
				.fill(color.opacity(0.12))
		)
	}
}

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

struct WindowFrameAutosave: NSViewRepresentable {
	let name: String

	func makeNSView(context: Context) -> WindowFrameAutosaveView {
		WindowFrameAutosaveView(name: name)
	}

	func updateNSView(_ nsView: WindowFrameAutosaveView, context: Context) {
		nsView.name = name
		nsView.applyAutosaveNameIfNeeded()
	}
}

final class WindowFrameAutosaveView: NSView {
	var name: String
	private var appliedWindowNumber: Int?

	init(name: String) {
		self.name = name
		super.init(frame: .zero)
	}

	required init?(coder: NSCoder) {
		return nil
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		applyAutosaveNameIfNeeded()
	}

	func applyAutosaveNameIfNeeded() {
		guard let window else { return }
		let windowNumber = window.windowNumber
		guard appliedWindowNumber != windowNumber else { return }
		appliedWindowNumber = windowNumber
		window.setFrameAutosaveName(name)
	}
}
