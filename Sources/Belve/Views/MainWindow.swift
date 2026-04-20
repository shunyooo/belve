import SwiftUI
import AppKit

struct MainWindow: View {
	@EnvironmentObject var commandPaletteState: CommandPaletteState
	@EnvironmentObject var projectStore: ProjectStore
	@State private var sidebarWidthAtDragStart: CGFloat = 0
	@State private var sessionBarWidthAtDragStart: CGFloat = 0
	@State private var openFile: OpenFile?
	@State private var showSettings = false
	@State private var isFileSearchPresented = false
	@State private var fileSearchQuery = ""
	@State private var fileSearchResults: [MainWindowFileSearchResult] = []
	@State private var selectedFileSearchIndex = 0
	@State private var isSearchingFiles = false
	@State private var fileSearchRevision = 0
	@State private var fileSearchWorkItem: DispatchWorkItem?
	@State private var fileSearchKeyMonitor: Any?
	@State private var paletteMode: PaletteMode = .commands
	@StateObject private var stateManager = CommandAreaStateManager()
	@StateObject private var layoutState = WorkspaceLayoutStateManager()
	@State private var browserPath: String = ""
	@State private var devContainerFlowHost: String? = nil
	@State private var focusZone: FocusZone = .pane
	@Namespace private var focusNamespace

	enum FocusZone {
		case pane
		case editor
		case fileTree
	}

	enum PaletteMode {
		case commands
		case sshHosts
		case sshHostsForDevContainer
		case folderBrowser
		case remoteDevContainerBrowser
	}

	var body: some View {
		configuredContent
			.environment(\.focusBorderNamespace, focusNamespace)
			.sheet(isPresented: $showSettings) {
				SettingsView()
			}
			.onReceive(NotificationCenter.default.publisher(for: .belveOpenSettings)) { _ in
				showSettings.toggle()
			}
	}

	private var configuredContent: AnyView {
		let base = AnyView(
			baseContent
				.background(Theme.bg)
				.background(WindowFrameAutosave(name: "BelveMainWindow"))
				.onAppear {
					sidebarWidthAtDragStart = layoutState.sidebarWidth
					// Restore the last-opened file for the currently selected project
					// on first launch (onChange of selectedProject doesn't fire for the
					// initial value, so we trigger it explicitly here).
					if let project = projectStore.selectedProject,
					   let path = layoutState.state(for: project.id).lastOpenedFile {
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
							NotificationCenter.default.post(
								name: .belveOpenFileFromTerminal,
								object: nil,
								userInfo: ["projectId": project.id, "path": path]
							)
						}
					}
				}
		)

		let projectShortcuts = AnyView(
			base
				.onReceive(NotificationCenter.default.publisher(for: .belveSwitchProject)) { notif in
					if let index = notif.userInfo?["index"] as? Int {
						projectStore.selectByIndex(index)
					}
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveSelectNextProject)) { _ in
					projectStore.selectNextProject()
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveSelectPreviousProject)) { _ in
					projectStore.selectPreviousProject()
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveFocusNextPane)) { _ in
					cycleFocus(step: 1)
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveFocusPreviousPane)) { _ in
					cycleFocus(step: -1)
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveEditorWebViewDidFocus)) { _ in
					focusZone = .editor
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveTerminalFocused)) { _ in
					focusZone = .pane
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveFileTreeFocused)) { _ in
					focusZone = .fileTree
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveFocusEditor)) { _ in
					projectStore.focusEditor()
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveOpenFileSearch)) { _ in
					presentFileSearch()
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveToggleEditor)) { _ in
					toggleEditor()
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveToggleSidebar)) { _ in
					toggleSidebar()
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveToggleSessionBar)) { _ in
					toggleSessionBar()
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveToggleFileTree)) { _ in
					toggleFileTree()
				}
		)

		let paletteHandlers = AnyView(
			projectShortcuts
				.onChange(of: projectStore.selectedProject) {
					openFile = nil
					// Restore the per-project last-opened file (if any) once the
					// PreviewArea for the new project is mounted.
					if let project = projectStore.selectedProject,
					   let path = layoutState.state(for: project.id).lastOpenedFile {
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
							NotificationCenter.default.post(
								name: .belveOpenFileFromTerminal,
								object: nil,
								userInfo: ["projectId": project.id, "path": path]
							)
						}
					}
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
						projectStore.refocusTerminal()
					}
				}
				.onChange(of: openFile?.path) {
					if let project = projectStore.selectedProject {
						layoutState.state(for: project.id).lastOpenedFile = openFile?.path
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
				.onReceive(NotificationCenter.default.publisher(for: .belveOpenFolder)) { _ in
					if commandPaletteState.isPresented && paletteMode == .folderBrowser {
						commandPaletteState.isPresented = false
					} else {
						openFolder()
					}
				}
		)

		return AnyView(
			paletteHandlers
				.onReceive(NotificationCenter.default.publisher(for: .belveFocusProject)) { notif in
					if let projectId = notif.userInfo?["projectId"] as? UUID,
					   let project = projectStore.projects.first(where: { $0.id == projectId }) {
						DispatchQueue.main.async { [self] in projectStore.select(project) }
					}
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveNewProject)) { _ in
					DispatchQueue.main.async { [self] in let _ = projectStore.addProject() }
				}
				.onReceive(NotificationCenter.default.publisher(for: .belveReloadProject)) { notif in
					DispatchQueue.main.async { [self] in
						if let projectId = notif.userInfo?["projectId"] as? UUID {
							projectStore.reloadProject(projectId)
						} else {
							projectStore.reloadCurrentProject()
						}
					}
				}
		)
	}

	private var baseContent: some View {
		ZStack {
			mainContent
			commandPaletteOverlay
			fileSearchOverlay
		}
	}

	private var mainContent: some View {
		HStack(spacing: 0) {
			if layoutState.showSidebar {
				sidebar
					.transition(.asymmetric(
						insertion: .modifier(
							active: SidebarVisibilityModifier(xOffset: -14, opacity: 0),
							identity: SidebarVisibilityModifier(xOffset: 0, opacity: 1)
						),
						removal: .modifier(
							active: SidebarVisibilityModifier(xOffset: -10, opacity: 0),
							identity: SidebarVisibilityModifier(xOffset: 0, opacity: 1)
						)
					))
			}

			VStack(spacing: 0) {
				topBar
				Theme.borderSubtle.frame(height: 1)
				projectContent
			}
			.background(Theme.surface)
		}
	}

	private var sidebar: some View {
		Group {
			ProjectListView(
				projects: projectStore.projects,
				selectedProject: Binding(
					get: { projectStore.selectedProject },
					set: { projectStore.select($0) }
				),
				onAddProject: { let _ = projectStore.addProject() },
				onToggleSidebar: toggleSidebar,
				onToggleSessionBar: toggleSessionBar,
				showSessionBar: layoutState.showSessionBar,
				onRenameProject: { id, name in projectStore.renameProject(id, name: name) },
				onDeleteProject: { id in projectStore.deleteProject(id) },
				onMoveProject: { source, dest in projectStore.moveProject(from: source, to: dest) }
			)
			.frame(width: layoutState.sidebarWidth)

			if layoutState.showSessionBar {
				// Divider: project bar ↔ session bar (drags project bar width)
				Rectangle()
					.fill(Theme.borderSubtle)
					.frame(width: 1)
					.contentShape(Rectangle().inset(by: -3))
					.onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
					.gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
						.onChanged { value in
							if sidebarWidthAtDragStart == 0 { sidebarWidthAtDragStart = layoutState.sidebarWidth }
							layoutState.sidebarWidth = max(100, min(300, sidebarWidthAtDragStart + value.translation.width))
						}
						.onEnded { _ in sidebarWidthAtDragStart = layoutState.sidebarWidth }
					)

				AgentSessionBar(
					projects: projectStore.projects,
					selectedProject: Binding(
						get: { projectStore.selectedProject },
						set: { projectStore.select($0) }
					),
					activeCommandState: commandAreaState(for: projectStore.selectedProject?.id ?? UUID()),
					onFocusPane: { projectId, paneId in
						if let paneUUID = UUID(uuidString: paneId) {
							commandAreaState(for: projectId).activePaneId = paneUUID
							projectStore.refocusTerminal(paneId: paneId)
						}
					},
					onToggle: toggleSessionBar
				)
				.frame(width: layoutState.sessionBarWidth)
				.transition(.asymmetric(
					insertion: .modifier(
						active: SidebarVisibilityModifier(xOffset: -14, opacity: 0),
						identity: SidebarVisibilityModifier(xOffset: 0, opacity: 1)
					),
					removal: .modifier(
						active: SidebarVisibilityModifier(xOffset: -10, opacity: 0),
						identity: SidebarVisibilityModifier(xOffset: 0, opacity: 1)
					)
				))

				// Divider: session bar ↔ terminal area (drags session bar width)
				Rectangle()
					.fill(Theme.borderSubtle)
					.frame(width: 1)
					.contentShape(Rectangle().inset(by: -3))
					.onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
					.gesture(
						DragGesture(minimumDistance: 1, coordinateSpace: .global)
							.onChanged { value in
								if sessionBarWidthAtDragStart == 0 {
									sessionBarWidthAtDragStart = layoutState.sessionBarWidth
								}
								layoutState.sessionBarWidth = max(100, min(300, sessionBarWidthAtDragStart + value.translation.width))
							}
							.onEnded { _ in
								sessionBarWidthAtDragStart = layoutState.sessionBarWidth
							}
					)
			}
		}
	}

	private var topBar: some View {
		TopBar(
			projectName: projectStore.selectedProject?.name ?? "",
			connectionInfo: projectStore.selectedProject.map { Self.connectionInfo(for: $0) } ?? nil,
			gitBranch: projectStore.gitBranch,
			showSidebar: layoutState.showSidebar,
			onToggleSidebar: toggleSidebar,
			sessionLabel: nil
		)
	}

	@ViewBuilder
	private var projectContent: some View {
		if !projectStore.projects.isEmpty {
			GeometryReader { geo in
				ZStack {
					ForEach(projectStore.projects) { project in
						projectWorkspace(for: project, availableWidth: geo.size.width)
					}
				}
			}
		} else {
			WelcomeView {
				let _ = projectStore.addProject()
			}
		}
	}

	private func projectWorkspace(for project: Project, availableWidth: CGFloat) -> some View {
		let isSelected = project.id == projectStore.selectedProject?.id
		let state = commandAreaState(for: project.id)
		let projectLayout = layoutState.state(for: project.id)
		let dividerWidth = DividerMetrics.absoluteHitWidth
		let splitBinding = Binding<CGFloat>(
			get: {
				let preferred = projectLayout.commandAreaFraction * availableWidth
				return min(max(250, preferred), max(250, availableWidth - 250))
			},
			set: { newValue in
				let clamped = min(max(250, newValue), max(250, availableWidth - 250))
				projectLayout.commandAreaFraction = clamped / max(availableWidth, 1)
			}
		)
		let clampedSplit = splitBinding.wrappedValue
		let isEditorVisible = projectLayout.showEditor
		let commandWidth = isEditorVisible ? clampedSplit : availableWidth
		let previewWidth = isEditorVisible ? max(0, availableWidth - clampedSplit - dividerWidth) : 0

		return ZStack(alignment: .bottomTrailing) {
			HStack(spacing: 0) {
				CommandArea(project: project, state: state)
					.id("command-\(project.id.uuidString)-\(projectStore.terminalReloadToken(for: project.id))")
					.frame(width: commandWidth)
					.environmentObject(state)

				SplitDivider(
					position: splitBinding,
					minLeft: 250,
					minRight: 250,
					availableWidth: availableWidth
				)
				.frame(width: isEditorVisible ? dividerWidth : 0)
				.opacity(isEditorVisible ? 1 : 0)
				.allowsHitTesting(isEditorVisible)
				.clipped()

				PreviewArea(
					project: project,
					layoutState: projectLayout,
					openFile: isSelected ? $openFile : .constant(nil)
				)
				.id(project.hashValue)
				.frame(width: previewWidth)
				.clipped()
				.modifier(PreviewVisibilityModifier(
					xOffset: isEditorVisible ? 0 : 14,
					opacity: isEditorVisible ? 1 : 0
				))
				.allowsHitTesting(isEditorVisible)
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
		.environment(\.projectActive, isSelected)
		.onChange(of: isSelected) { _, nowSelected in
			if nowSelected {
				// Force re-fit terminals after becoming visible
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					NotificationCenter.default.post(
						name: .belveTerminalRefit,
						object: nil,
						userInfo: ["projectId": project.id]
					)
				}
				// Focus terminal after project switch (delay past refit layout)
				let targetPaneId = commandAreaState(for: project.id).activePaneId
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
					projectStore.refocusTerminal(paneId: targetPaneId?.uuidString)
				}
			}
		}
	}

	@ViewBuilder
	private var commandPaletteOverlay: some View {
		if commandPaletteState.isPresented {
			Color.black.opacity(0.3)
				.ignoresSafeArea()
				.onTapGesture {
					commandPaletteState.isPresented = false
				}

			VStack {
				switch paletteMode {
				case .folderBrowser:
					FolderBrowserView(
						isPresented: $commandPaletteState.isPresented,
						initialPath: browserPath,
						provider: projectStore.selectedProject?.provider ?? LocalProvider(path: nil)
					) { path in
						projectStore.setProjectFolder(path)
					}
					.padding(.top, 80)
				case .remoteDevContainerBrowser:
					if let host = devContainerFlowHost {
						FolderBrowserView(
							isPresented: $commandPaletteState.isPresented,
							initialPath: browserPath,
							provider: SSHProvider(host: host, path: nil),
							highlightDevContainers: true
						) { path in
							projectStore.openRemoteDevContainerOnCurrent(host: host, workspacePath: path)
							devContainerFlowHost = nil
						}
						.padding(.top, 80)
					}
				default:
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

	@ViewBuilder
	private var fileSearchOverlay: some View {
		if isFileSearchPresented {
			GeometryReader { geo in
				Color.black.opacity(0.16)
					.ignoresSafeArea()
					.onTapGesture {
						closeFileSearch()
					}

				VStack {
					HStack {
						Spacer(minLength: 0)
						MainWindowFileSearchPanel(
							availableHeight: geo.size.height,
							query: $fileSearchQuery,
							results: fileSearchResults,
							selectedIndex: $selectedFileSearchIndex,
							isSearching: isSearchingFiles,
							onSubmit: openSelectedFileSearchResult,
							onCancel: closeFileSearch,
							onSelect: { result in
								openFileSearchResult(result)
							}
						)
						.id(projectStore.selectedProject?.id)
						.onAppear {
							scheduleFileSearch()
						}
						.onChange(of: fileSearchQuery) {
							selectedFileSearchIndex = 0
							scheduleFileSearch()
						}
						Spacer(minLength: 0)
					}
					.padding(.top, 80)
					Spacer()
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			}
		}
	}

	private func cycleFocus(step: Int) {
		guard let project = projectStore.selectedProject else { return }
		let projectLayout = layoutState.state(for: project.id)
		let state = commandAreaState(for: project.id)

		// Build a flat cycle: each terminal pane counts individually,
		// followed by file tree (if shown) and editor (if shown).
		enum Stop: Equatable {
			case pane(UUID)
			case editor
			case fileTree
		}

		var stops: [Stop] = state.orderedPaneIds().map { .pane($0) }
		if projectLayout.showEditor {
			if projectLayout.showFileTree { stops.append(.fileTree) }
			// Editor is only a cycle stop when a file is actually open; otherwise
			// there's nothing to focus and the placeholder is just a blank area.
			if openFile != nil { stops.append(.editor) }
		}
		guard !stops.isEmpty else { return }

		let currentStop: Stop = {
			switch focusZone {
			case .editor: return .editor
			case .fileTree: return .fileTree
			case .pane:
				if let active = state.activePaneId, stops.contains(.pane(active)) {
					return .pane(active)
				}
				return stops.first!
			}
		}()

		let currentIndex = stops.firstIndex(of: currentStop) ?? 0
		let nextIndex = (currentIndex + step + stops.count) % stops.count
		let nextStop = stops[nextIndex]

		withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)) {
			switch nextStop {
			case .pane(let paneId):
				focusZone = .pane
				state.activePaneId = paneId
			case .editor:
				focusZone = .editor
			case .fileTree:
				focusZone = .fileTree
			}
		}

		// Side effects (making AppKit first responder) happen outside animation.
		switch nextStop {
		case .pane(let paneId):
			projectStore.refocusTerminal(paneId: paneId.uuidString)
		case .editor:
			projectStore.focusEditor()
		case .fileTree:
			NotificationCenter.default.post(
				name: .belveFocusFileTree,
				object: nil,
				userInfo: ["projectId": project.id]
			)
		}
	}

	private func toggleSidebar() {
		let isShowing = !layoutState.showSidebar
		withAnimation(Self.toggleAnimation(isShowing: isShowing)) {
			layoutState.showSidebar.toggle()
		}
	}

	private func toggleSessionBar() {
		let isShowing = !layoutState.showSessionBar
		withAnimation(Self.toggleAnimation(isShowing: isShowing)) {
			layoutState.showSessionBar.toggle()
		}
	}

	private func toggleFileTree() {
		guard let project = projectStore.selectedProject else { return }
		let projectLayout = layoutState.state(for: project.id)
		guard projectLayout.showEditor else { return }
		let isShowing = !projectLayout.showFileTree
		withAnimation(Self.toggleAnimation(isShowing: isShowing)) {
			projectLayout.showFileTree.toggle()
		}
		if projectLayout.showFileTree {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
				NotificationCenter.default.post(
					name: .belveFocusFileTree,
					object: nil,
					userInfo: ["projectId": project.id]
				)
			}
		} else {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
				projectStore.refocusTerminal()
			}
		}
	}

	private func toggleEditor() {
		guard let project = projectStore.selectedProject else { return }
		let projectLayout = layoutState.state(for: project.id)
		let isShowing = !projectLayout.showEditor
		withAnimation(Self.toggleAnimation(isShowing: isShowing)) {
			projectLayout.showEditor.toggle()
		}
		if projectLayout.showEditor {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
				projectStore.focusEditor()
			}
		} else {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
				projectStore.refocusTerminal()
			}
		}
	}

	private func presentFileSearch() {
		if isFileSearchPresented {
			closeFileSearch()
			return
		}
		guard let project = projectStore.selectedProject else { return }
		let projectLayout = layoutState.state(for: project.id)
		if !projectLayout.showEditor {
			withAnimation(Self.toggleAnimation(isShowing: true)) {
				projectLayout.showEditor = true
			}
		}
		withAnimation(.easeOut(duration: 0.12)) {
			isFileSearchPresented = true
		}
		installFileSearchKeyMonitor()
	}

	private func closeFileSearch() {
		withAnimation(.easeOut(duration: 0.1)) {
			isFileSearchPresented = false
		}
		fileSearchWorkItem?.cancel()
		fileSearchQuery = ""
		fileSearchResults = []
		selectedFileSearchIndex = 0
		isSearchingFiles = false
		removeFileSearchKeyMonitor()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
			projectStore.refocusTerminal()
		}
	}

	private func scheduleFileSearch() {
		fileSearchWorkItem?.cancel()
		let query = fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else {
			fileSearchResults = []
			isSearchingFiles = false
			return
		}

		let revision = fileSearchRevision + 1
		fileSearchRevision = revision
		let workItem = DispatchWorkItem {
			runFileSearch(query: query, revision: revision)
		}
		fileSearchWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
	}

	private func runFileSearch(query: String, revision: Int) {
		guard let project = projectStore.selectedProject else { return }
		isSearchingFiles = true
		DispatchQueue.global(qos: .userInitiated).async {
			let matches = project.provider.searchFileNames(rootPath: project.effectivePath, query: query, limit: 60)
			let results = matches.map {
				MainWindowFileSearchResult(
					path: $0.path,
					relativePath: relativeDisplayPath($0.path, rootPath: project.effectivePath),
					lineNumber: $0.lineNumber,
					snippet: $0.snippet,
					matchedFilename: $0.matchedFilename
				)
			}
			DispatchQueue.main.async {
				guard revision == fileSearchRevision else { return }
				fileSearchResults = results
				isSearchingFiles = false
			}
		}
	}

	private func openSelectedFileSearchResult() {
		guard selectedFileSearchIndex >= 0,
			  selectedFileSearchIndex < fileSearchResults.count else { return }
		openFileSearchResult(fileSearchResults[selectedFileSearchIndex])
	}

	private func openFileSearchResult(_ result: MainWindowFileSearchResult) {
		guard let project = projectStore.selectedProject else { return }
		closeFileSearch()
		NotificationCenter.default.post(
			name: .belveOpenFileFromTerminal,
			object: nil,
			userInfo: [
				"projectId": project.id,
				"path": result.path,
				"line": result.lineNumber as Any
			]
		)
	}

	private func relativeDisplayPath(_ path: String, rootPath: String) -> String {
		var relative = path
		if rootPath != ".", path.hasPrefix(rootPath) {
			relative = String(path.dropFirst(rootPath.count))
			if relative.hasPrefix("/") {
				relative.removeFirst()
			}
		}
		if relative.hasPrefix("./") {
			relative = String(relative.dropFirst(2))
		}
		return relative.isEmpty ? (path as NSString).lastPathComponent : relative
	}

	private func moveFileSearchSelection(by delta: Int) {
		guard !fileSearchResults.isEmpty else { return }
		selectedFileSearchIndex = min(max(0, selectedFileSearchIndex + delta), fileSearchResults.count - 1)
	}

	private func installFileSearchKeyMonitor() {
		guard fileSearchKeyMonitor == nil else { return }
		fileSearchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			guard isFileSearchPresented else { return event }
			switch event.keyCode {
			case 125:
				moveFileSearchSelection(by: 1)
				return nil
			case 126:
				moveFileSearchSelection(by: -1)
				return nil
			case 36:
				openSelectedFileSearchResult()
				return nil
			case 53:
				closeFileSearch()
				return nil
			default:
				return event
			}
		}
	}

	private func removeFileSearchKeyMonitor() {
		if let fileSearchKeyMonitor {
			NSEvent.removeMonitor(fileSearchKeyMonitor)
			self.fileSearchKeyMonitor = nil
		}
	}

	// MARK: - Command Palette

	private func buildPaletteCommands() -> [PaletteCommand] {
		switch paletteMode {
		case .commands:
			return buildMainCommands()
		case .sshHosts:
			return buildSSHHostCommands()
		case .sshHostsForDevContainer:
			return buildSSHHostCommandsForDevContainer()
		case .folderBrowser, .remoteDevContainerBrowser:
			return []
		}
	}

	private static func toggleAnimation(isShowing: Bool) -> Animation {
		isShowing
			? .interpolatingSpring(stiffness: 1280, damping: 56)
			: .easeOut(duration: 0.05)
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

		cmds.append(PaletteCommand(title: "Open Remote DevContainer", icon: "shippingbox", keepOpen: true) {
			paletteMode = .sshHostsForDevContainer
		})

		if let project = projectStore.selectedProject, project.sshHost != nil {
			if project.isDevContainer {
				cmds.append(PaletteCommand(title: "Reopen without Container (SSH)", icon: "arrow.uturn.backward") {
					projectStore.closeDevContainer()
				})
				cmds.append(PaletteCommand(title: "Rebuild DevContainer", icon: "arrow.triangle.2.circlepath") {
					projectStore.rebuildDevContainer()
				})
			} else if projectStore.showDevContainerBanner {
				// Only show "Reopen in Container" when .devcontainer/devcontainer.json exists
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
		cmds.append(PaletteCommand(title: "Toggle Session List", icon: "sidebar.squares.left") {
			withAnimation(.easeOut(duration: 0.15)) { layoutState.showSessionBar.toggle() }
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

	private func buildSSHHostCommandsForDevContainer() -> [PaletteCommand] {
		SSHConfigParser.parse().map { host in
			PaletteCommand(title: host.name, icon: "network", keepOpen: true) {
				devContainerFlowHost = host.name
				browserPath = "~"
				paletteMode = .remoteDevContainerBrowser
			}
		}
	}

	// MARK: - Folder Browser

	private static func connectionInfo(for project: Project) -> String? {
		let label = project.provider.displayLabel
		return label.isEmpty ? nil : label
	}

	private func commandAreaState(for projectId: UUID) -> CommandAreaState {
		stateManager.state(for: projectId)
	}

	private func openFolder() {
		// Always start at the home directory (local = NSHomeDirectory, remote = "~").
		// Don't carry over the project's current workspace path — the browser is
		// used to pick a new folder, not to confirm the existing one.
		if projectStore.selectedProject?.sshHost != nil {
			browserPath = "~"
		} else {
			browserPath = NSHomeDirectory()
		}
		paletteMode = .folderBrowser
		commandPaletteState.isPresented = true
	}
}

// MARK: - Focus border namespace (shared across Command panes, file tree, editor)

private struct FocusNamespaceKey: EnvironmentKey {
	static let defaultValue: Namespace.ID? = nil
}

private struct ProjectActiveKey: EnvironmentKey {
	static let defaultValue: Bool = true
}

extension EnvironmentValues {
	var focusBorderNamespace: Namespace.ID? {
		get { self[FocusNamespaceKey.self] }
		set { self[FocusNamespaceKey.self] = newValue }
	}
	var projectActive: Bool {
		get { self[ProjectActiveKey.self] }
		set { self[ProjectActiveKey.self] = newValue }
	}
}

struct FocusBorderOverlay: View {
	let isActive: Bool
	@Environment(\.focusBorderNamespace) private var namespace
	@Environment(\.projectActive) private var projectActive

	var body: some View {
		ZStack {
			if isActive && projectActive, let ns = namespace {
				RoundedRectangle(cornerRadius: 4)
					.strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.2)
					.matchedGeometryEffect(id: "belveFocusBorder", in: ns, properties: .frame, isSource: true)
					.allowsHitTesting(false)
			}
		}
	}
}

private struct SidebarVisibilityModifier: ViewModifier {
	let xOffset: CGFloat
	let opacity: Double

	func body(content: Content) -> some View {
		content
			.opacity(opacity)
			.offset(x: xOffset)
	}
}

private struct PreviewVisibilityModifier: ViewModifier {
	let xOffset: CGFloat
	let opacity: Double

	func body(content: Content) -> some View {
		content
			.opacity(opacity)
			.offset(x: xOffset)
	}
}

private struct MainWindowFileSearchResult: Identifiable, Hashable {
	let id = UUID()
	let path: String
	let relativePath: String
	let lineNumber: Int?
	let snippet: String?
	let matchedFilename: Bool
}

private struct MainWindowFileSearchPanel: View {
	let availableHeight: CGFloat
	@Binding var query: String
	let results: [MainWindowFileSearchResult]
	@Binding var selectedIndex: Int
	let isSearching: Bool
	let onSubmit: () -> Void
	let onCancel: () -> Void
	let onSelect: (MainWindowFileSearchResult) -> Void
	@FocusState private var isFocused: Bool

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(Theme.textTertiary)

				TextField("Search files...", text: $query)
					.textFieldStyle(.plain)
					.font(.system(size: 14))
					.foregroundStyle(Theme.textPrimary)
					.focused($isFocused)
					.onSubmit {
						onSubmit()
					}

				if isSearching {
					Text("Searching…")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(Theme.textSecondary)
				} else if !query.isEmpty {
					Text("\(results.count)")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(Theme.textSecondary)
				}
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 12)

			Theme.borderSubtle.frame(height: 1)

			Group {
				if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					searchEmptyState("Type to search files")
				} else if results.isEmpty && isSearching {
					searchEmptyState("Searching…")
				} else if results.isEmpty {
					searchEmptyState("No matches")
				} else {
					ScrollViewReader { proxy in
						ScrollView {
							VStack(spacing: 0) {
								ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
									MainWindowFileSearchRow(result: result, isSelected: index == selectedIndex)
										.id(result.id)
										.onTapGesture {
											selectedIndex = index
											onSelect(result)
										}
								}
							}
						}
						.onChange(of: selectedIndex) {
							guard selectedIndex >= 0, selectedIndex < results.count else { return }
							withAnimation(.easeOut(duration: 0.12)) {
								proxy.scrollTo(results[selectedIndex].id, anchor: .center)
							}
						}
						.onAppear {
							guard selectedIndex >= 0, selectedIndex < results.count else { return }
							proxy.scrollTo(results[selectedIndex].id, anchor: .center)
						}
					}
					.frame(maxHeight: .infinity)
				}
			}
		}
		.frame(width: 560, height: max(360, availableHeight - 120), alignment: .top)
		.background(Theme.surface)
		.cornerRadius(Theme.radiusLg)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusLg)
				.stroke(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.34), radius: 18, y: 8)
		.onAppear {
			isFocused = true
		}
	}

	private func searchEmptyState(_ label: String) -> some View {
		HStack {
			Text(label)
				.font(.system(size: 12))
				.foregroundStyle(Theme.textSecondary)
			Spacer()
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 14)
	}

}

private struct MainWindowFileSearchRow: View {
	let result: MainWindowFileSearchResult
	let isSelected: Bool
	@State private var isHovering = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 8) {
				Image(systemName: result.matchedFilename ? "doc.text" : "text.alignleft")
					.font(.system(size: 11))
					.foregroundStyle(Theme.textSecondary)
					.frame(width: 14)

				Text((result.path as NSString).lastPathComponent)
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(Theme.textPrimary)
					.lineLimit(1)

				Spacer()

				if let lineNumber = result.lineNumber {
					Text("L\(lineNumber)")
						.font(.system(size: 10, weight: .semibold))
						.foregroundStyle(Theme.textSecondary)
				}
			}

			Text(result.relativePath)
				.font(.system(size: 11))
				.foregroundStyle(Theme.textSecondary)
				.lineLimit(1)

			if let snippet = result.snippet, !snippet.isEmpty {
				Text(snippet)
					.font(.system(size: 11))
					.foregroundStyle(Theme.textPrimary.opacity(0.88))
					.lineLimit(2)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 9)
		.background(isSelected ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
		.onHover { isHovering = $0 }
	}
}

// MARK: - Top Bar

struct TopBar: View {
	let projectName: String
	let connectionInfo: String?  // e.g. "SSH: host", "DevContainer: host", nil for local
	var gitBranch: String?
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

			if let branch = gitBranch {
				HStack(spacing: 3) {
					Image(systemName: "arrow.triangle.branch")
						.font(.system(size: 9))
					Text(branch)
						.font(.system(size: 10, weight: .medium))
				}
				.foregroundStyle(Theme.accent)
				.padding(.horizontal, 6)
				.padding(.vertical, 2)
				.background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.12)))
			}

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
		window.tabbingMode = .disallowed
	}
}
