import Foundation
import SwiftUI
import WebKit

/// Project の接続失敗状態。SSH host が落ちてる / network 不通等。
/// `ProjectStore.connectionErrors[projectId]` で CommandArea から観測される。
/// Set されてる間は pane を隠して overlay 表示。
struct ConnectionError {
	enum Kind {
		case hostUnreachable  // ssh: connect to host ... timed out / Connection refused / Connection closed
		case authFailed       // Permission denied (publickey)
		case other(String)    // 上記に当てはまらない (raw error 表示)
	}
	let kind: Kind
	let host: String
	let detail: String       // 元 error 文字列 (debug 用に残す)
	let occurredAt: Date

	/// master.ensureSetup の error から ConnectionError を組み立てる。
	/// マッチしない場合は `.other` で raw を保持。
	static func classify(host: String, error: Error) -> ConnectionError {
		let raw = error.localizedDescription
		let lower = raw.lowercased()
		let kind: Kind
		if lower.contains("connection closed")
			|| lower.contains("connection refused")
			|| lower.contains("timed out")
			|| lower.contains("no route to host")
			|| lower.contains("operation timed out")
			|| lower.contains("network is unreachable") {
			kind = .hostUnreachable
		} else if lower.contains("permission denied") || lower.contains("publickey") {
			kind = .authFailed
		} else {
			kind = .other(raw)
		}
		return ConnectionError(kind: kind, host: host, detail: raw, occurredAt: Date())
	}

	var headline: String {
		switch kind {
		case .hostUnreachable: return "Host unreachable"
		case .authFailed:      return "SSH authentication failed"
		case .other:           return "Connection failed"
		}
	}

	var hint: String {
		switch kind {
		case .hostUnreachable: return "VM が落ちている / network 不通の可能性。VM を起動するか接続を確認してください。"
		case .authFailed:      return "SSH 鍵 or known_hosts を確認してください。"
		case .other(let raw):  return raw
		}
	}
}

/// Manages project lifecycle: CRUD, persistence, selection, and state reset.
/// Single source of truth for project state — all project mutations go through here.
class ProjectStore: ObservableObject {
	@Published var projects: [Project] = []
	@Published var selectedProject: Project?
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
	/// Per-project connection error。SSH host 不通等。Set されてる間 pane を
	/// 隠して `HostUnreachableOverlayView` を出す。retry 成功 or dismiss で消える。
	@Published var connectionErrors: [UUID: ConnectionError] = [:]
	private var lastGitRefresh: Date = .distantPast

	private var gitPollTimer: Timer?
	/// Local project の selected 時に動かす FSEventStream watcher (local 専用)。
	/// remote は RPC push 経由で別系統。selectedProject が変わるたびに rebind。
	private let localFileWatcher = LocalFileWatcher()
	/// fsevent push 購読済みの project ID。多重購読を防ぐ。
	private var rpcSubscribed: Set<UUID> = []
	private var rpcSubscribedClient: [UUID: RemoteRPCClient] = [:]
	/// fsevent → refresh の debounce タイマー (project ごと)。
	private var fsRefreshTimers: [UUID: DispatchWorkItem] = [:]

	init() {
		if let saved = UserDefaults.standard.string(forKey: "Belve.defaultGroupName"), !saved.isEmpty {
			defaultGroupName = saved
		}
		// Local file watcher: callback で .git 配下を除外しつつ debounced refresh
		// を発火 (= 既存の scheduleFsRefresh と同じ debounce 経路に乗せる)。
		localFileWatcher.onChanged = { [weak self] paths in
			guard let self, let projectId = self.selectedProject?.id else { return }
			let nonGit = paths.contains { p in
				!p.contains("/.git/") && !p.hasSuffix("/.git")
			}
			guard nonGit else { return }
			self.scheduleFsRefresh(projectId: projectId)
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

		// SSH host 不通等の接続失敗を XTermTerminalView から受け取り、
		// connectionErrors に格納 → CommandArea が overlay 表示。
		NotificationCenter.default.addObserver(
			forName: .belveProjectConnectionError, object: nil, queue: .main
		) { [weak self] notif in
			guard let self,
				  let projectId = notif.userInfo?["projectId"] as? UUID,
				  let host = notif.userInfo?["host"] as? String,
				  let error = notif.userInfo?["error"] as? Error else { return }
			self.setConnectionError(projectId, host: host, error: error)
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

		bumpTerminalReload(for: projectId)
		objectWillChange.send()
		NSLog("[Belve] Reloaded project: \(project.name)")
	}

	func terminalReloadToken(for projectId: UUID) -> Int {
		terminalReloadTokens[projectId, default: 0]
	}

	/// 該当 project の全 pane を破棄して terminal を再 spawn させる。
	/// PaneHostRegistry の strong ref も外す (= 古い WebView/PTY が deinit される)。
	/// CommandArea の `.id(...token...)` 変更が SwiftUI の再 mount をトリガーし、
	/// 新規 XTermTerminalView が registry cache miss → 新 WebView + 新 PTYService。
	private func bumpTerminalReload(for projectId: UUID) {
		PaneHostRegistry.shared.unregisterAll(in: projectId)
		terminalReloadTokens[projectId, default: 0] += 1
	}

	// MARK: - Selection

	/// Select a project, resetting all project-scoped state.
	func select(_ project: Project?) {
		if selectedProject?.id == project?.id { return }
		let t0 = Date()
		selectedProject = project
		// 切替後にターミナルへ focus を戻す。SwiftUI が新 project の view を
		// mount し終わる時間を見て短い delay 後に refocus する。
		if project != nil {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
				self?.refocusTerminal()
			}
		}
		// 永続化: 起動時に同じ project を復元するため UserDefaults へ id を保存。
		if let id = project?.id {
			UserDefaults.standard.set(id.uuidString, forKey: "Belve.selectedProjectId")
		} else {
			UserDefaults.standard.removeObject(forKey: "Belve.selectedProjectId")
		}
		defer {
			let dt = Date().timeIntervalSince(t0) * 1000
			if dt > 30 { NSLog("[Belve][select][slow] %.0fms project=%@", dt, project?.name ?? "nil") }
		}
		refreshGitStatus()
		if let project {
			Task { @MainActor in LSPManager.shared.activate(project: project) }
		}
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
			// Remote project に切替えたので local watcher は止める。
			localFileWatcher.stop()
		} else if let p = project, !p.isRemote {
			// Local project に切替え: rootPath を watch する。同 path なら no-op。
			// SwiftUI が select() 起因の layout pass を終えてから watcher を
			// 起動 (= FSEventStream callback が in-flight render と race して
			// NSView removal で crash する症状の回避、2026-05-05)。
			let root = p.effectivePath
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				if !root.isEmpty {
					self.localFileWatcher.start(rootPath: root)
				} else {
					self.localFileWatcher.stop()
				}
			}
		} else {
			localFileWatcher.stop()
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
		guard let client = RemoteRPCRegistry.shared.client(for: projectId) else { return }
		guard !rpcSubscribed.contains(projectId) || rpcSubscribedClient[projectId] !== client else { return }
		rpcSubscribed.insert(projectId)
		rpcSubscribedClient[projectId] = client
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
		// TCP 内部再接続で broker 側の watch (per-connection) が消えるので、
		// 再接続のたびに root watch を登録し直す (再接続時のみ発火)。
		client.subscribeReconnect { [weak client] in
			guard let client else { return }
			Task { _ = try? await client.send(op: "watch", params: ["path": rootPath]) }
		}
		Task { @MainActor in
			_ = try? await client.send(op: "watch", params: ["path": rootPath])
		}
	}

	private func scheduleFsRefresh(projectId: UUID) {
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

			var expanded: [String: String] = [:]
			for (filePath, status) in rawStatus {
				expanded[filePath] = status
				var dir = (filePath as NSString).deletingLastPathComponent
				while !dir.isEmpty && dir != "." {
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
	/// Cmd+] / Cmd+[ の cycle 対象 (= pinned があれば pinned のみ、なければ全
	/// project)。MainWindow からも view 横断 cycle で同じスコープを使うために
	/// 公開している。alias: `cycleProjects`。
	var cycleProjects: [Project] { cycleScope }

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
		// Forwards target the VM host's 127.0.0.1.
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
		let newProjectId = project.id
		Task { @MainActor in ProjectViewStore.shared.ensureMainView(for: newProjectId) }
		select(project)
		return project
	}

	func deleteProject(_ id: UUID) {
		if let host = projects.first(where: { $0.id == id })?.sshHost {
			SSHTunnelManager.shared.teardownTunnel(host: host, projectId: id)
		}
		// Pane WebView / PTY を解放 (registry の strong ref を外して deinit させる)。
		PaneHostRegistry.shared.unregisterAll(in: id)
		projects.removeAll { $0.id == id }
		if selectedProject?.id == id {
			select(projects.first)
		}
		Task { @MainActor in ProjectViewStore.shared.teardown(projectId: id) }
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

	// MARK: - Connection Errors

	/// 接続失敗を記録 (= overlay 表示)。`XTermTerminalView` の startPTY で
	/// master.ensureSetup が失敗した時に呼ぶ。
	func setConnectionError(_ projectId: UUID, host: String, error: Error) {
		connectionErrors[projectId] = ConnectionError.classify(host: host, error: error)
	}

	/// `HostUnreachableOverlayView` の "Retry" / "Dismiss" 両方から呼ぶ。
	/// terminalReloadTokens を bump して PTY を再 spawn (= 再 ensureSetup)。
	/// 同じ host に他に project がある場合はそれらの error も合わせてクリア
	/// (= host が復旧してれば全部繋がるはず)。
	func clearConnectionError(_ projectId: UUID) {
		// host を取得して、master 側 cache + stale ControlMaster を reset
		let host = projects.first(where: { $0.id == projectId })?.sshHost
		if let host {
			Task {
				try? await MasterClient.shared.resetHostHealth(host: host)
			}
			// 同 host の他 project の error も全部消す
			let sameHostIds = projects.filter { $0.sshHost == host }.map(\.id)
			for id in sameHostIds {
				connectionErrors.removeValue(forKey: id)
				bumpTerminalReload(for: id)
			}
		} else {
			connectionErrors.removeValue(forKey: projectId)
			bumpTerminalReload(for: projectId)
		}
		objectWillChange.send()
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

	/// Replace a project with a new ID to force terminal recreation.
	private func replaceWithNewId(at index: Int, updated: Project) {
		let newProject = updated.withNewId()
		projects[index] = newProject
		saveProjects()
		select(newProject)
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
		// Phase 1: 既存 project が ProjectViewStore に未登録 (= views.json 移行
		// 後に新規追加された project や、views.json 自体が存在しない初回起動) の
		// 場合に備えて、全 project に main view を保証する。idempotent なので
		// 多重呼び出しでも害なし。
		Task { @MainActor in
			for p in migrated {
				ProjectViewStore.shared.ensureMainView(for: p.id)
			}
		}
		// 永続化された前回 select の project を復元 (= 起動毎に top にリセットされる
		// のを防ぐ)。UUID が現存する project と一致しなければ先頭に fallback。
		let savedId = UserDefaults.standard.string(forKey: "Belve.selectedProjectId")
			.flatMap { UUID(uuidString: $0) }
		if let sid = savedId, let restored = decoded.first(where: { $0.id == sid }) {
			selectedProject = restored
		} else {
			selectedProject = decoded.first
		}
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
		let workspacePath = p.path ?? ""
		let rh = remoteHostForForward(p)
		PortForwardManager.shared.sync(project: p, host: host, remoteHost: rh)
		PortForwardManager.shared.registerForScanning(projectId: p.id, host: host)
		// Phase 2 (master 化): まず master に setup を投げる。Master 側で
		// per-host 直列化 + idempotent state 管理されてるので並列に呼んで OK。
		if let binDir = Self.belveBinDir() {
			do {
				try await MasterClient.shared.ensureSetup(
					projectId: p.id,
					host: host,
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

		// mux 経由。SSH forward (19201) は mac-master が yamux session
		// 確立時に張る (= ここで触らない)。registerControlMux は Unix
		// socket endpoint で RPC client を構築する。
		RemoteRPCRegistry.shared.registerControlMux(
			projectId: p.id, host: host, projShort: projShort
		)
		self.subscribeRPCFsEvents(projectId: p.id, rootPath: p.effectivePath)
		self.fetchAndCacheCwd(for: p.id)
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
