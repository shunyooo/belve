import Foundation
import SwiftUI
import WebKit

/// DevContainer rebuild の進捗状態。`ProjectStore.rebuildStates[projectId]` で
/// CommandArea から観測される。Set されてる間はペインを隠して overlay 表示。
struct RebuildState {
	enum Phase { case running, success, failed }
	var phase: Phase
	var log: [String]
	var startedAt: Date

	mutating func appendLine(_ line: String) {
		log.append(line)
		// 直近 500 行だけ保持 (大量出力で memory 食わないように)
		if log.count > 500 {
			log.removeFirst(log.count - 500)
		}
	}
}

/// Manages project lifecycle: CRUD, persistence, selection, and state reset.
/// Single source of truth for project state — all project mutations go through here.
class ProjectStore: ObservableObject {
	@Published var projects: [Project] = []
	@Published var selectedProject: Project?
	@Published var showDevContainerBanner = false
	@Published private var terminalReloadTokens: [UUID: Int] = [:]
	@Published var gitBranch: String?
	@Published var gitFileStatus: [String: String] = [:]  // relativePath → status (M, A, D, ??, etc.)
	/// Group header names the user has collapsed. Pinned section has its own
	/// implicit key `"__pinned__"` so it can also be folded.
	@Published var collapsedGroups: Set<String> = []
	/// 新規 project が自動的に所属する group 名。ユーザーがサイドバーで
	/// rename すると変わる。UserDefaults に永続化。
	@Published var defaultGroupName: String = "Inbox" {
		didSet { UserDefaults.standard.set(defaultGroupName, forKey: "Belve.defaultGroupName") }
	}

	// Per-project loading state, aggregated from pane-level terminal-connection
	// notifications. Used by the sidebar to show a "Preparing DevContainer..." hint.
	@Published var projectLoadingStatus: [UUID: String] = [:]
	private var projectLoadingPanes: [UUID: Set<UUID>] = [:]
	/// Per-project rebuild state. Set when `rebuildDevContainer` starts and
	/// cleared on completion. While set, CommandArea hides panes and shows
	/// `RebuildOverlayView` instead. Streaming `belve-setup --rebuild` output
	/// is appended to `log` as it arrives via master push events.
	@Published var rebuildStates: [UUID: RebuildState] = [:]
	private var pushSubscribed = false
	private var lastGitRefresh: Date = .distantPast

	private var gitPollTimer: Timer?
	/// fsevent push 購読済みの project ID。多重購読を防ぐ。
	private var rpcSubscribed: Set<UUID> = []
	/// fsevent → refresh の debounce タイマー (project ごと)。
	private var fsRefreshTimers: [UUID: DispatchWorkItem] = [:]

	init() {
		if let saved = UserDefaults.standard.string(forKey: "Belve.defaultGroupName"), !saved.isEmpty {
			defaultGroupName = saved
		}
		loadProjects()
		loadCollapsedGroups()
		observePortDetections()
		// Git status: backstop poll at 30s. Most updates flow via push (fsevent
		// → debounced refresh in `subscribeRPCFsEvents`) so this is just a
		// safety net for missed events / non-watched paths.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
			self?.refreshGitStatus(force: true)
			self?.gitPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
				self?.refreshGitStatus()
			}
		}

		// Aggregate pane-level connection loading state into per-project loading state
		// so the project sidebar can show "Preparing DevContainer..." etc.
		NotificationCenter.default.addObserver(
			forName: .belveTerminalConnectionState, object: nil, queue: .main
		) { [weak self] notif in
			guard let self,
				  let projectId = notif.userInfo?["projectId"] as? UUID,
				  let paneIdString = notif.userInfo?["paneId"] as? String,
				  let paneId = UUID(uuidString: paneIdString),
				  let isLoading = notif.userInfo?["isLoading"] as? Bool else { return }
			var set = self.projectLoadingPanes[projectId] ?? []
			if isLoading {
				set.insert(paneId)
			} else {
				set.remove(paneId)
			}
			if set.isEmpty {
				self.projectLoadingPanes.removeValue(forKey: projectId)
				self.projectLoadingStatus.removeValue(forKey: projectId)
			} else {
				self.projectLoadingPanes[projectId] = set
			}
		}

		NotificationCenter.default.addObserver(
			forName: .belveTerminalConnectionStatus, object: nil, queue: .main
		) { [weak self] notif in
			guard let self,
				  let projectId = notif.userInfo?["projectId"] as? UUID else { return }
			if let message = notif.userInfo?["message"] as? String {
				self.projectLoadingStatus[projectId] = message
			} else {
				self.projectLoadingStatus.removeValue(forKey: projectId)
			}
		}
	}

	// MARK: - Reload

	/// Reload the current project (re-create terminal, file tree, etc.)
	/// Uses ID change to force SwiftUI view recreation without nil transition.
	func reloadCurrentProject() {
		guard let projectId = selectedProject?.id else { return }
		reloadProject(projectId)
	}

	func reloadProject(_ projectId: UUID) {
		guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
		let project = projects[index]

		// Refresh project metadata without recreating terminals
		if project.isDevContainer, let sshHost = project.sshHost, let workspacePath = project.path {
			fetchContainerImageName(sshHost: sshHost, remotePath: workspacePath)
		}

		terminalReloadTokens[projectId, default: 0] += 1
		objectWillChange.send()
		NSLog("[Belve] Reloaded project: \(project.name)")
	}

	func terminalReloadToken(for projectId: UUID) -> Int {
		terminalReloadTokens[projectId, default: 0]
	}

	// MARK: - Selection

	/// Select a project, resetting all project-scoped state.
	func select(_ project: Project?) {
		if selectedProject?.id == project?.id { return }
		let t0 = Date()
		selectedProject = project
		defer {
			let dt = Date().timeIntervalSince(t0) * 1000
			if dt > 30 { NSLog("[Belve][select][slow] %.0fms project=%@", dt, project?.name ?? "nil") }
		}
		showDevContainerBanner = false
		if project?.sshHost != nil && !(project?.isDevContainer ?? false) {
			checkForDevContainer()
		}
		refreshGitStatus()
		NSLog("[Belve][select] project=%@ sshHost=%@",
		      project?.name ?? "nil",
		      project?.sshHost ?? "nil")
		// 現在の active project を PortForwardManager に伝える (= scan を 1
		// project に絞る adaptive scope policy)。
		Task { @MainActor in PortForwardManager.shared.setActiveProjectId(project?.id) }
		if let p = project, p.sshHost != nil {
			Task { @MainActor in
				await self.setupRemoteRPC(for: p)
			}
		}
	}

	/// 1度だけ subscribe して、project の rootPath を watch する。fsevent は
	/// 250ms debounce の後 `refreshGitStatus()` + `belveRefreshFileTree`
	/// notification をトリガする。多重購読は `rpcSubscribed` で防ぐ。
	///
	/// 注意: `.git` は監視しない (= git status の実行自体が `.git/index.lock` を
	/// create/delete する → fsevent → refresh → git status → 無限ループ)。
	/// commit / checkout / stage 後の状態変化は 30s の backstop polling で拾う。
	/// `.git` 内の "本物の" 変更だけ抽出する path filter を入れれば watch を
	/// 復活できるが、現状は安全側で disabled。
	private func subscribeRPCFsEvents(projectId: UUID, rootPath: String) {
		guard !rpcSubscribed.contains(projectId) else { return }
		guard let client = RemoteRPCRegistry.shared.client(for: projectId) else { return }
		rpcSubscribed.insert(projectId)
		client.subscribePush { [weak self] type, msg in
			guard type == "fsevent" else { return }
			// .git 配下の event は無視 (path が ".git/..." or ".../.git/..." 等
			// 様々な形で来る。先頭にスラッシュ無しのケースも catch する)。
			if let path = msg["path"] as? String,
			   path.hasPrefix(".git/") || path.contains("/.git/") || path.hasSuffix("/.git") || path == ".git" {
				return
			}
			DispatchQueue.main.async {
				self?.scheduleFsRefresh(projectId: projectId)
			}
		}
		Task { @MainActor in
			_ = try? await client.send(op: "watch", params: ["path": rootPath])
		}
	}

	private func scheduleFsRefresh(projectId: UUID) {
		// 既存の予約をキャンセル → 新しい 250ms タイマー。バースト fs 変更を
		// 1 回の refresh に束ねる。
		fsRefreshTimers[projectId]?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			guard self.selectedProject?.id == projectId else { return }
			self.refreshGitStatus(force: true)
			NotificationCenter.default.post(name: .belveRefreshFileTree, object: nil)
		}
		fsRefreshTimers[projectId] = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
	}

	func refreshGitStatus(force: Bool = false) {
		// Throttle: skip if refreshed within last 2 seconds
		if !force && Date().timeIntervalSince(lastGitRefresh) < 2 { return }
		lastGitRefresh = Date()
		guard let project = selectedProject else {
			gitBranch = nil
			gitFileStatus = [:]
			return
		}
		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			let provider = project.provider
			let path = project.effectivePath
			let branch = provider.gitBranch(path)
			let rawStatus = provider.gitStatus(path)

			// Build expanded map: include parent directories
			// e.g. "Sources/Belve/foo.swift" → "M" also adds "Sources/Belve" → "M", "Sources" → "M"
			var expanded: [String: String] = [:]
			for (filePath, status) in rawStatus {
				expanded[filePath] = status
				// Add all parent directories
				var dir = (filePath as NSString).deletingLastPathComponent
				while !dir.isEmpty && dir != "." {
					// Directory gets highest-priority status: M > A > D > ??
					if let existing = expanded[dir] {
						expanded[dir] = Self.mergeGitStatus(existing, status)
					} else {
						expanded[dir] = status
					}
					dir = (dir as NSString).deletingLastPathComponent
				}
			}

			DispatchQueue.main.async {
				// 値が変わってない時は @Published を触らない。
				// SwiftUI の subscribe がノーオプで返る (値同じなら no-op だが、
				// `gitFileStatus` を読んでる View は publisher 通知だけで body
				// 再評価される。コンテンツが同じでも最帰着で flicker の原因になる)。
				if self?.gitBranch != branch {
					self?.gitBranch = branch
				}
				if self?.gitFileStatus != expanded {
					self?.gitFileStatus = expanded
				}
			}
		}
	}

	private static func mergeGitStatus(_ a: String, _ b: String) -> String {
		let priority = ["M": 3, "D": 2, "A": 1, "??": 0]
		return (priority[a] ?? 0) >= (priority[b] ?? 0) ? a : b
	}

	/// Select project by index (for Cmd+1-9).
	func selectByIndex(_ index: Int) {
		guard index >= 0, index < projects.count else { return }
		select(projects[index])
	}

	/// If any projects are pinned, cycle only through the pinned set. Otherwise
	/// cycle through every project (falls back to the full list).
	private var cycleScope: [Project] {
		let pinned = projects.filter { $0.isPinned }
		return pinned.isEmpty ? projects : pinned
	}

	func selectNextProject() {
		let scope = cycleScope
		guard !scope.isEmpty else { return }
		let currentIndex = scope.firstIndex(where: { $0.id == selectedProject?.id }) ?? -1
		let nextIndex = (currentIndex + 1) % scope.count
		select(scope[nextIndex])
	}

	func selectPreviousProject() {
		let scope = cycleScope
		guard !scope.isEmpty else { return }
		let currentIndex = scope.firstIndex(where: { $0.id == selectedProject?.id }) ?? 0
		let previousIndex = (currentIndex - 1 + scope.count) % scope.count
		select(scope[previousIndex])
	}

	func togglePin(_ id: UUID) {
		guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
		projects[index].isPinned.toggle()
		saveProjects()
	}

	// MARK: - Groups

	/// Distinct non-empty group names in first-appearance order. Default group
	/// は projects に member が無くても常に頭に出すかどうかは呼び出し側で選択。
	var groupNames: [String] {
		var seen = Set<String>()
		var result: [String] = []
		for p in projects where !p.groupName.isEmpty {
			let g = p.groupName
			if !seen.contains(g) {
				seen.insert(g)
				result.append(g)
			}
		}
		return result
	}

	/// 空文字 / nil は default group を当てる (= 必ずどこかに属する)。
	func setProjectGroup(_ id: UUID, groupName: String?) {
		guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
		let trimmed = (groupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		projects[index].groupName = trimmed.isEmpty ? defaultGroupName : trimmed
		saveProjects()
	}

	/// Rename a group by rewriting every member's `groupName`. Preserves
	/// collapse state under the new name.
	func renameGroup(from oldName: String, to newName: String) {
		let newTrimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !newTrimmed.isEmpty, oldName != newTrimmed else { return }
		// If a group with `newTrimmed` already exists, the projects will simply
		// merge into it — that's an acceptable behavior for duplicate names.
		for i in projects.indices where projects[i].groupName == oldName {
			projects[i].groupName = newTrimmed
		}
		if collapsedGroups.contains(oldName) {
			collapsedGroups.remove(oldName)
			collapsedGroups.insert(newTrimmed)
			saveCollapsedGroups()
		}
		saveProjects()
	}

	/// Move a project to the sidebar section identified by `sectionKey`.
	/// The same mechanism powers both the context-menu actions and drag-and-drop
	/// onto a section header. Keys:
	/// - `"__pinned__"` → pin the project (leaves its `groupName` alone so unpin
	///   returns it to its original group)
	/// - `""` → ungroup + unpin (drop into the tail empty area)
	/// - any other string → treat as a group name; unpin since pinned projects
	///   render in the Pinned section regardless of group.
	func moveProjectToSection(_ id: UUID, sectionKey: String) {
		guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
		if sectionKey == "__pinned__" {
			projects[index].isPinned = true
		} else if sectionKey.isEmpty {
			// 「グループから外す」操作 → default group に戻す (空にしない)。
			projects[index].isPinned = false
			projects[index].groupName = defaultGroupName
		} else {
			projects[index].isPinned = false
			projects[index].groupName = sectionKey
		}
		saveProjects()
	}

	// MARK: - Port Forwards

	func updateProjectForwards(_ id: UUID, forwards: [PortForward]) {
		guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
		projects[index].portForwards = forwards
		if selectedProject?.id == id { selectedProject = projects[index] }
		saveProjects()
		if let host = projects[index].sshHost {
			let project = projects[index]
			let remoteHost = remoteHostForForward(project)
			Task { @MainActor in
				PortForwardManager.shared.sync(project: project, host: host, remoteHost: remoteHost)
			}
		}
	}

	private func remoteHostForForward(_ project: Project) -> String {
		// For DevContainer, forwards currently target the VM host's 127.0.0.1.
		// Container-IP targeting can be added later once the `.env` is readable
		// via the existing SSH ControlMaster.
		"127.0.0.1"
	}

	// MARK: - Auto-detected port forwards

	private func observePortDetections() {
		NotificationCenter.default.addObserver(
			forName: .belvePortDetected, object: nil, queue: .main
		) { [weak self] notif in
			guard let self,
				  let projectId = notif.userInfo?["projectId"] as? UUID,
				  let port = notif.userInfo?["port"] as? Int else { return }
			self.handleDetectedPort(projectId: projectId, port: port)
		}
	}

	private func handleDetectedPort(projectId: UUID, port: Int) {
		guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
		let project = projects[index]
		NSLog("[Belve][scan] handleDetectedPort project=%@ port=%d existingForwards=%d blocked=%@ allowed=%@",
			project.name, port,
			project.portForwards.count,
			project.portForwardBlocklist.contains(port) ? "Y" : "N",
			project.portForwardAllowlist.contains(port) ? "Y" : "N")

		// Already configured as a forward — nothing to do
		if project.portForwards.contains(where: { $0.remotePort == port }) { return }
		// Blocked by user — silently ignore
		if project.portForwardBlocklist.contains(port) { return }
		// Allowlisted → auto-forward (no toast)
		if project.portForwardAllowlist.contains(port) {
			var updated = project.portForwards
			updated.append(PortForward(localPort: port, remotePort: port, enabled: true, autoDetected: true))
			updateProjectForwards(projectId, forwards: updated)
			return
		}
		// Otherwise ask the user via toast
		Task { @MainActor in
			PortForwardManager.shared.surfaceDetection(projectId: projectId, port: port)
			NSLog("[Belve][scan] surfaced toast port=%d pending=%d",
				port, PortForwardManager.shared.pendingDetections[projectId]?.count ?? 0)
		}
	}

	/// Respond to the user's choice on a detection toast.
	func resolvePortDetection(projectId: UUID, port: Int, action: PortForwardManager.DetectionAction) {
		guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
		var project = projects[index]
		switch action {
		case .forwardOnce:
			project.portForwards.append(PortForward(localPort: port, remotePort: port, enabled: true, autoDetected: true))
		case .always:
			project.portForwardAllowlist.insert(port)
			project.portForwards.append(PortForward(localPort: port, remotePort: port, enabled: true, autoDetected: true))
		case .never:
			project.portForwardBlocklist.insert(port)
		case .dismissOnce:
			break
		}
		projects[index] = project
		if selectedProject?.id == projectId { selectedProject = project }
		saveProjects()
		Task { @MainActor in
			PortForwardManager.shared.resolveDetection(projectId: projectId, remotePort: port, action: action)
			if let host = project.sshHost {
				let rh = self.remoteHostForForward(project)
				PortForwardManager.shared.sync(project: project, host: host, remoteHost: rh)
			}
		}
	}

	/// Produce a group name not yet used. Used when the user asks to create a
	/// new group — the caller then edits it in-place.
	func uniqueGroupName(base: String = "New Group") -> String {
		let existing = Set(groupNames)
		if !existing.contains(base) { return base }
		var i = 2
		while existing.contains("\(base) \(i)") { i += 1 }
		return "\(base) \(i)"
	}

	func toggleGroupCollapse(_ name: String) {
		if collapsedGroups.contains(name) {
			collapsedGroups.remove(name)
		} else {
			collapsedGroups.insert(name)
		}
		saveCollapsedGroups()
	}

	func isGroupCollapsed(_ name: String) -> Bool {
		collapsedGroups.contains(name)
	}

	// MARK: - CRUD

	func addProject(name: String? = nil, sshHost: String? = nil) -> Project {
		let baseName = name ?? NSHomeDirectory().components(separatedBy: "/").last ?? "Project"
		let finalName = uniqueName(baseName)
		let workspace: Workspace = sshHost.map { .ssh(host: $0, path: nil) } ?? .local(path: nil)
		let project = Project(
			name: finalName,
			workspace: workspace,
			groupName: defaultGroupName
		)
		projects.append(project)
		saveProjects()
		select(project)
		return project
	}

	func deleteProject(_ id: UUID) {
		if let host = projects.first(where: { $0.id == id })?.sshHost {
			SSHTunnelManager.shared.teardownTunnel(host: host, projectId: id)
		}
		projects.removeAll { $0.id == id }
		if selectedProject?.id == id {
			select(projects.first)
		}
		saveProjects()
	}

	private func uniqueName(_ base: String) -> String {
		let existing = Set(projects.map(\.name))
		if !existing.contains(base) { return base }
		var i = 2
		while existing.contains("\(base) \(i)") { i += 1 }
		return "\(base) \(i)"
	}

	func moveProject(from source: IndexSet, to destination: Int) {
		projects.move(fromOffsets: source, toOffset: destination)
		saveProjects()
	}

	func renameProject(_ id: UUID, name: String) {
		guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
		projects[index].name = name
		if selectedProject?.id == id {
			selectedProject = projects[index]
		}
		saveProjects()
	}

	// MARK: - Folder / Path

	func setProjectFolder(_ path: String) {
		let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let index = indexOfSelected else { return }

		// Teardown existing tunnel — project ID is about to change (withNewId below)
		if let host = projects[index].sshHost {
			SSHTunnelManager.shared.teardownTunnel(host: host, projectId: projects[index].id)
		}

		// Kill old persist sessions and clean sockets
		let projShort = String(projects[index].id.uuidString.prefix(8))
		let sessionsDir = "/tmp/belve-shell/sessions"
		let pkill = Process()
		pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
		pkill.arguments = ["-f", "belve-persist.*belve-\(projShort)"]
		try? pkill.run()
		pkill.waitUntilExit()
		if let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) {
			for file in files where file.hasPrefix("belve-\(projShort)") {
				try? FileManager.default.removeItem(atPath: (sessionsDir as NSString).appendingPathComponent(file))
			}
		}

		// Replace with a fresh project (new ID = clean slate for layout, sessions, etc.)
		// Preserve connection type, update path
		let oldProject = projects[index]
		let newWorkspace: Workspace
		switch oldProject.workspace {
		case .local:
			newWorkspace = .local(path: path)
		case .ssh(let host, _):
			newWorkspace = .ssh(host: host, path: path)
		case .devContainer(let host, _):
			newWorkspace = .devContainer(host: host, workspace: path)
		}
		let newProject = Project(
			name: (path as NSString).lastPathComponent,
			workspace: newWorkspace,
			isPinned: oldProject.isPinned,
			groupName: oldProject.groupName
		)
		projects[index] = newProject
		saveProjects()
		select(newProject)
		NSLog("[Belve] Opened folder: \(path)")
	}

	/// Send text as input to the currently focused terminal's PTY
	func sendToActiveTerminal(_ text: String) {
		guard let webView = findTerminalWebView() else { return }
		let b64 = Data(text.utf8).base64EncodedString()
		webView.evaluateJavaScript(
			"window.webkit.messageHandlers.terminalHandler.postMessage({type:'input',data:'\(b64)'})",
			completionHandler: nil
		)
	}

	/// Refocus the terminal view after palette/dialog closes
	func refocusTerminal(paneId: String? = nil) {
		guard let webView = findTerminalWebView(paneId: paneId) else {
			NSLog("[Belve] refocusTerminal: webview not found for paneId=\(paneId ?? "nil")")
			return
		}
		// Proactively tell SwiftUI-focused siblings (file tree / editor) to release focus
		// before we take AppKit first responder. Otherwise @FocusState can race and keep
		// the caret trapped there, so typing doesn't reach the terminal webview.
		NotificationCenter.default.post(name: .belveTerminalFocused, object: webView)

		// @FocusState can re-assert focus to its bound view on later runloop ticks
		// (SwiftUI batches focus updates). Claim aggressively on multiple ticks so
		// the terminal wins even if a sibling tries to reclaim.
		let claim = {
			guard let win = webView.window else {
				NSLog("[Belve] refocusTerminal: webView has no window")
				return
			}
			// Main window が key じゃないと typing が届かない (browser panel
			// などが key を奪ってる場合)。makeKey 強制 + first responder 設定。
			if !win.isKeyWindow { win.makeKeyAndOrderFront(nil) }
			win.makeFirstResponder(nil)
			let ok = win.makeFirstResponder(webView)
			webView.evaluateJavaScript("terminalFocus(true)", completionHandler: nil)
			NSLog("[Belve] refocusTerminal claim isKey=%d ok=%d window=%@",
			      win.isKeyWindow ? 1 : 0,
			      ok ? 1 : 0,
			      win.identifier?.rawValue ?? String(describing: type(of: win)))
		}
		claim()
		DispatchQueue.main.async { claim() }
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { claim() }
	}

	private func findTerminalWebView(paneId: String? = nil) -> WKWebView? {
		let targetIdentifier = paneId.map { "BelveTerminalWebView:\($0)" }

		// 全 windows を walk して terminal webview を探す。keyWindow が
		// browser panel などに奪われてても main window 内の terminal を
		// 見つけられる。
		var all: [(String, NSWindow)] = []
		func collect(_ view: NSView, in window: NSWindow) {
			if let v = view as? WKWebView, let id = v.identifier?.rawValue,
			   id.hasPrefix("BelveTerminalWebView") {
				all.append((id, window))
			}
			for sub in view.subviews { collect(sub, in: window) }
		}
		for window in NSApp.windows where window.isVisible {
			if let root = window.contentView {
				collect(root, in: window)
			}
		}
		// 見つかった webview の親 window を target に
		let target: (NSWindow, NSView)? = {
			if let id = targetIdentifier, let hit = all.first(where: { $0.0 == id }) {
				return (hit.1, hit.1.contentView!)
			}
			if let any = all.first {
				return (any.1, any.1.contentView!)
			}
			return nil
		}()
		guard let (_, root) = target else { return nil }

		func find(_ view: NSView, requireTarget: Bool) -> WKWebView? {
			if let v = view as? WKWebView, let id = v.identifier?.rawValue,
			   id.hasPrefix("BelveTerminalWebView") {
				if requireTarget {
					if let targetIdentifier, id == targetIdentifier { return v }
				} else {
					return v
				}
			}
			for sub in view.subviews {
				if let found = find(sub, requireTarget: requireTarget) { return found }
			}
			return nil
		}
		if targetIdentifier != nil {
			if let hit = find(root, requireTarget: true) { return hit }
		}
		return find(root, requireTarget: false)
	}

	func focusEditor() {
		guard let window = NSApp.keyWindow,
			  let projectId = selectedProject?.id else { return }
		let targetIdentifier = "BelveEditorWebView:\(projectId.uuidString)"

		func find(_ view: NSView) -> WKWebView? {
			if let v = view as? WKWebView, v.identifier?.rawValue == targetIdentifier { return v }
			for sub in view.subviews {
				if let found = find(sub) { return found }
			}
			return nil
		}

		guard let webView = find(window.contentView ?? window.contentView!) else { return }
		webView.window?.makeFirstResponder(webView)
		webView.evaluateJavaScript(
			"window.focus(); window.editorFocus?.(); window.markdownFocus?.(); setTimeout(() => { window.editorFocus?.(); window.markdownFocus?.(); }, 0);",
			completionHandler: nil
		)
	}

	// MARK: - SSH

	func connectSSH(host: String) {
		if let index = indexOfSelected {
			let oldProject = projects[index]
			let name = oldProject.path == nil ? (host.components(separatedBy: ".").first ?? host) : oldProject.name
			// groupName / isPinned を継承しないと、サイドバーが known group の
			// projects だけを描画する仕組みのため新 project が消える。
			let newProject = Project(
				name: name,
				workspace: .ssh(host: host, path: oldProject.path),
				isPinned: oldProject.isPinned,
				groupName: oldProject.groupName
			)
			projects[index] = newProject
			saveProjects()
			select(newProject)
			// Reload terminal to connect via LauncherScriptGenerator
			reloadCurrentProject()
		} else {
			let _ = addProject(name: host.components(separatedBy: ".").first, sshHost: host)
		}
	}

	// MARK: - DevContainer

	/// Reconfigure the currently selected project as a remote DevContainer in one step.
	/// Combines "SSH Connect + Open Folder + Reopen in Container".
	///
	/// Callers must have already verified that `.devcontainer/devcontainer.json`
	/// exists at workspacePath (the folder browser does this for the Open Remote
	/// DevContainer command). No SSH fallback — if the dir isn't a devcontainer,
	/// this method shouldn't be called.
	func openRemoteDevContainerOnCurrent(host: String, workspacePath: String) {
		let baseName = (workspacePath as NSString).lastPathComponent
		let workspace: Workspace = .devContainer(host: host, workspace: workspacePath)

		if let index = indexOfSelected {
			if let oldHost = projects[index].sshHost {
				SSHTunnelManager.shared.teardownTunnel(host: oldHost, projectId: projects[index].id)
			}
			let oldProject = projects[index]
			let replacement = Project(
				name: baseName.isEmpty ? oldProject.name : baseName,
				workspace: workspace,
				isPinned: oldProject.isPinned,
				groupName: oldProject.groupName
			).withNewId()
			projects[index] = replacement
			saveProjects()
			select(replacement)
			fetchContainerImageName(sshHost: host, remotePath: workspacePath)
			// Master 経由の container setup を triggering (overlay + ライブログ表示)。
			// rebuild と同じ UX で初回 `devcontainer up` の進捗が見える。
			triggerInitialDevContainerSetup(replacement.id)
			NSLog("[Belve] Reconfigured project \(replacement.name) @ \(host):\(workspacePath) as DevContainer")
		} else {
			let finalName = uniqueName(baseName.isEmpty ? host : baseName)
			// 新規 project は default group に入れる (= サイドバーで filter されない)
			let project = Project(name: finalName, workspace: workspace, groupName: defaultGroupName)
			projects.append(project)
			saveProjects()
			select(project)
			fetchContainerImageName(sshHost: host, remotePath: workspacePath)
			triggerInitialDevContainerSetup(project.id)
			NSLog("[Belve] Added project \(finalName) @ \(host):\(workspacePath) as DevContainer")
		}
	}

	func openDevContainer() {
		guard let index = indexOfSelected,
			  let sshHost = projects[index].sshHost,
			  let workspacePath = projects[index].path else {
			NSLog("[Belve] Cannot open DevContainer: no path set. Use Cmd+O first.")
			return
		}
		let newProject = Project(
			name: (workspacePath as NSString).lastPathComponent,
			workspace: .devContainer(host: sshHost, workspace: workspacePath)
		)
		projects[index] = newProject
		saveProjects()
		select(newProject)
		fetchContainerImageName(sshHost: sshHost, remotePath: workspacePath)
		triggerInitialDevContainerSetup(newProject.id)
		NSLog("[Belve] DevContainer enabled for \(newProject.name)")
	}

	/// Rebuild DevContainer: master daemon に依頼 + overlay UI 表示。
	/// `runContainerSetup(forceRebuild: true)` のラッパー。
	func rebuildDevContainer() {
		guard let index = indexOfSelected,
		      case .devContainer(let sshHost, let workspace) = projects[index].workspace else {
			NSLog("[Belve] rebuildDevContainer: no DevContainer selected")
			return
		}
		let p = projects[index]
		runContainerSetup(
			projectId: p.id, projectName: p.name,
			sshHost: sshHost, workspacePath: workspace,
			forceRebuild: true,
			initialMessage: "Requesting rebuild of \(p.name)…"
		)
	}

	/// SSH → Open Remote DevContainer 等で初回 container 起動を triggering する時に呼ぶ。
	/// `runContainerSetup(forceRebuild: false)` のラッパー。
	/// (cached `.env` あれば belve-setup は fast path、無ければ devcontainer up 新規実行)
	func triggerInitialDevContainerSetup(_ projectId: UUID) {
		guard let index = projects.firstIndex(where: { $0.id == projectId }),
		      case .devContainer(let sshHost, let workspace) = projects[index].workspace else {
			return
		}
		let p = projects[index]
		runContainerSetup(
			projectId: p.id, projectName: p.name,
			sshHost: sshHost, workspacePath: workspace,
			forceRebuild: false,
			initialMessage: "Preparing container for \(p.name)…"
		)
	}

	/// Master 経由の container setup (rebuild / 初回共通)。
	/// - per-host serialize (master 側 sync.Mutex)
	/// - setup state invalidate → belve-setup → markReady
	/// - 進捗を push event で受けて `rebuildStates[projId].log` に流す
	/// - CommandArea が `rebuildStates[projId]` を観測してペインを隠して overlay 表示
	private func runContainerSetup(
		projectId: UUID,
		projectName: String,
		sshHost: String,
		workspacePath: String,
		forceRebuild: Bool,
		initialMessage: String
	) {
		// 既に進行中なら無視 (二重起動防止)
		if rebuildStates[projectId]?.phase == .running {
			NSLog("[Belve] runContainerSetup: already running for \(projectName)")
			return
		}
		subscribeMasterPushEventsIfNeeded()

		let projShort = String(projectId.uuidString.prefix(8))

		// 即座に state set → UI が overlay を出す + ペイン token bump で既存 PTY を teardown
		rebuildStates[projectId] = RebuildState(
			phase: .running,
			log: [initialMessage],
			startedAt: Date()
		)
		terminalReloadTokens[projectId, default: 0] += 1
		objectWillChange.send()

		guard let binDir = Self.belveBinDir() else {
			rebuildStates[projectId]?.appendLine("ERROR: belve binary directory not found")
			rebuildStates[projectId]?.phase = .failed
			return
		}

		Task.detached(priority: .userInitiated) { [weak self] in
			do {
				try await MasterClient.shared.rebuildSetup(
					projectId: projectId,
					host: sshHost,
					workspacePath: workspacePath,
					projShort: projShort,
					binDir: binDir,
					forceRebuild: forceRebuild
				)
				await MainActor.run {
					self?.rebuildStates[projectId]?.phase = .success
					self?.rebuildStates[projectId]?.appendLine("✓ Container ready. Reconnecting panes…")
				}
				try? await Task.sleep(nanoseconds: 1_500_000_000)
				await MainActor.run {
					self?.rebuildStates.removeValue(forKey: projectId)
					self?.terminalReloadTokens[projectId, default: 0] += 1
					self?.objectWillChange.send()
				}
			} catch {
				await MainActor.run {
					self?.rebuildStates[projectId]?.phase = .failed
					self?.rebuildStates[projectId]?.appendLine("ERROR: \(error.localizedDescription)")
				}
			}
		}
		NSLog("[Belve] runContainerSetup: requested for \(projectName) forceRebuild=\(forceRebuild)")
	}

	/// `RebuildOverlayView` の "Dismiss" / "Retry" ボタンから呼ばれる。
	func dismissRebuildState(_ projectId: UUID) {
		rebuildStates.removeValue(forKey: projectId)
		terminalReloadTokens[projectId, default: 0] += 1
		objectWillChange.send()
	}

	private func subscribeMasterPushEventsIfNeeded() {
		guard !pushSubscribed else { return }
		pushSubscribed = true
		MasterClient.shared.subscribePush(type: "rebuildProgress") { [weak self] payload in
			guard let self else { return }
			guard let pidStr = payload["projectId"] as? String,
			      let projId = UUID(uuidString: pidStr) else { return }
			let line = payload["line"] as? String ?? ""
			DispatchQueue.main.async {
				self.rebuildStates[projId]?.appendLine(line)
			}
		}
	}

	func disconnectSSH() {
		guard let index = indexOfSelected else { return }
		let oldProject = projects[index]
		let name = oldProject.name
		if let host = oldProject.sshHost {
			SSHTunnelManager.shared.teardownTunnel(host: host, projectId: oldProject.id)
		}
		// groupName / isPinned 継承で sidebar から消えないように。
		let newProject = Project(
			name: name,
			workspace: .local(path: nil),
			isPinned: oldProject.isPinned,
			groupName: oldProject.groupName
		)
		projects[index] = newProject
		saveProjects()
		select(newProject)
		NSLog("[Belve] SSH disconnected for \(name), reverted to local")
	}

	func closeDevContainer() {
		guard let index = indexOfSelected else { return }
		let old = projects[index]
		guard let sshHost = old.sshHost else { return }
		SSHTunnelManager.shared.teardownTunnel(host: sshHost, projectId: old.id)
		let newProject = Project(
			name: old.name,
			workspace: .ssh(host: sshHost, path: old.path),
			isPinned: old.isPinned,
			groupName: old.groupName
		)
		projects[index] = newProject
		saveProjects()
		select(newProject)
		NSLog("[Belve] DevContainer disabled, reverting to SSH")
	}

	/// Replace a project with a new ID to force terminal recreation.
	private func replaceWithNewId(at index: Int, updated: Project) {
		let newProject = updated.withNewId()
		projects[index] = newProject
		saveProjects()
		select(newProject)
	}

	private func fetchContainerImageName(sshHost: String, remotePath: String) {
		// Container image name is no longer stored on Project.
		// DevContainerProvider.displayLabel provides a static label.
		// This method is kept as a no-op for future enhancement.
		NSLog("[Belve] DevContainer detected at \(remotePath) on \(sshHost)")
	}

	private func checkForDevContainer() {
		guard let project = selectedProject,
			  project.sshHost != nil,
			  let remotePath = project.path,
			  !project.isDevContainer else { return }

		let provider = project.provider
		DispatchQueue.global().async { [weak self] in
			let hasDevContainer = provider.fileExists("\(remotePath)/.devcontainer/devcontainer.json")
				|| provider.fileExists("\(remotePath)/.devcontainer.json")
			DispatchQueue.main.async {
				withAnimation(.easeOut(duration: 0.2)) {
					self?.showDevContainerBanner = hasDevContainer
				}
			}
		}
	}

	// MARK: - Persistence

	private var indexOfSelected: Int? {
		projects.firstIndex(where: { $0.id == selectedProject?.id })
	}

	private static var projectsFileURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("projects.json")
	}

	private static var collapsedGroupsFileURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("collapsed-groups.json")
	}

	private func loadCollapsedGroups() {
		guard let data = try? Data(contentsOf: Self.collapsedGroupsFileURL),
			  let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
		collapsedGroups = Set(decoded)
	}

	private func saveCollapsedGroups() {
		if let data = try? JSONEncoder().encode(Array(collapsedGroups)) {
			try? data.write(to: Self.collapsedGroupsFileURL)
		}
	}

	private func loadProjects() {
		guard let data = try? Data(contentsOf: Self.projectsFileURL),
			  let decoded = try? JSONDecoder().decode([Project].self, from: data),
			  !decoded.isEmpty else {
			projects = [Project(name: "Project 1", groupName: defaultGroupName)]
			return
		}
		// Migration: groupName が空の (= legacy ungrouped) project を default
		// group に紐付け直す。
		var migrated = decoded
		var didMigrate = false
		for i in migrated.indices where migrated[i].groupName.isEmpty {
			migrated[i].groupName = defaultGroupName
			didMigrate = true
		}
		projects = migrated
		if didMigrate {
			saveProjects()
		}
		selectedProject = decoded.first
		let initialActiveId = selectedProject?.id
		Task { @MainActor in PortForwardManager.shared.setActiveProjectId(initialActiveId) }
		// RPC client の eager 登録は AppDelegate.didFinishLaunching が
		// teardownAll を終えた後に `setupAllRemoteRPC()` を呼ぶことで行う。
		// ここで spawn すると teardownAll と race して全部失敗する。
	}

	/// AppDelegate.didFinishLaunching から呼ばれる。全 remote project の
	/// RPC client を eager 登録する。PreviewArea (keep-alive で全 project ぶん
	/// 構築される) の file watch が RPC 経路で揃うので、polling fallback の
	/// 暴走が起きない。
	func setupAllRemoteRPC() {
		for p in projects where p.sshHost != nil {
			Task { @MainActor in
				await self.setupRemoteRPC(for: p)
			}
		}
	}

	/// Project 1 つぶんの remote ops 初期化:
	///   PortForwardManager.sync + scan 登録 + SSH router forward + RPC client 登録 + fsevent 購読
	/// `select()` と `loadProjects()` 両方から呼ぶので、両者で同等のセットアップ
	/// を保証する。
	@MainActor
	private func setupRemoteRPC(for p: Project) async {
		guard let host = p.sshHost else { return }
		let projShort = String(p.id.uuidString.prefix(8))
		let isDev = p.isDevContainer
		let workspacePath = p.path ?? ""
		let rh = remoteHostForForward(p)
		PortForwardManager.shared.sync(project: p, host: host, remoteHost: rh)
		PortForwardManager.shared.registerForScanning(projectId: p.id, host: host, isDevContainer: isDev)
		do {
			// Phase 2 (master 化): まず master に setup を投げる。Master 側で
			// per-host 直列化 + idempotent state 管理されてるので並列に呼んで OK。
			// 失敗しても今は launcher が保険で同じ事をやるので fall through する
			// (Phase 2b で launcher 側を撤廃したらここの failure を厳格化する)。
			if let binDir = Self.belveBinDir() {
				do {
					try await MasterClient.shared.ensureSetup(
						projectId: p.id,
						host: host,
						isDevContainer: isDev,
						workspacePath: workspacePath,
						projShort: projShort,
						binDir: binDir
					)
					NSLog("[Belve][master] ensureSetup ok project=%@", String(p.id.uuidString.prefix(8)))
				} catch {
					NSLog("[Belve][master] ensureSetup failed project=%@ error=%@",
					      String(p.id.uuidString.prefix(8)), error.localizedDescription)
				}
			}

			let routerLocalPort = try await SSHTunnelManager.shared.ensureRouterForward(host: host)
			RemoteRPCRegistry.shared.registerControlPort(
				projectId: p.id,
				localPort: UInt16(routerLocalPort),
				projShort: projShort
			)
			self.subscribeRPCFsEvents(projectId: p.id, rootPath: p.effectivePath)
			self.fetchAndCacheCwd(for: p.id)
		} catch {
			NSLog("[Belve][rpc] setup failed project=%@ error=%@",
				  String(p.id.uuidString.prefix(8)), error.localizedDescription)
		}
	}

	/// Belve.app bundle 内の bin dir。Master が deploy_bundle で remote に
	/// 送るファイル (belve / claude / belve-setup / belve-persist-linux-* /
	/// session-bootstrap.sh) の置き場。
	private static func belveBinDir() -> String? {
		if let resourcePath = Bundle.main.resourcePath {
			return (resourcePath as NSString).appendingPathComponent("bin")
		}
		// Dev fallback (SPM 直叩き、本番では走らない)
		let dev = "/Users/s07309/src/dock-code/Belve.app/Contents/Resources/bin"
		if FileManager.default.fileExists(atPath: dev) { return dev }
		return nil
	}

	/// Brokerに `pwd` op を発行して cwd (= ワークスペースの絶対パス) を取得し
	/// `RemoteRPCRegistry` に保存する。DevContainer の `effectivePath` は `.`
	/// なので、ファイルツリーの "Copy Full Path" でこの値を prefix として
	/// 使って `./tasks/...` を `/workspaces/.../tasks/...` に解決する。
	private func fetchAndCacheCwd(for projectId: UUID) {
		guard let client = RemoteRPCRegistry.shared.client(for: projectId) else { return }
		Task.detached {
			do {
				let res = try await client.send(op: "pwd", params: [:])
				if let cwd = res.result?["cwd"] as? String, !cwd.isEmpty {
					RemoteRPCRegistry.shared.setCwd(cwd, for: projectId)
				}
			} catch {
				NSLog("[Belve][rpc] pwd failed project=%@ error=%@",
				      String(projectId.uuidString.prefix(8)), error.localizedDescription)
			}
		}
	}

	func saveProjects() {
		if let data = try? JSONEncoder().encode(projects) {
			try? data.write(to: Self.projectsFileURL)
		}
	}
}
