import Foundation
import SwiftUI
import WebKit

/// Manages project lifecycle: CRUD, persistence, selection, and state reset.
/// Single source of truth for project state — all project mutations go through here.
class ProjectStore: ObservableObject {
	@Published var projects: [Project] = []
	@Published var selectedProject: Project?
	@Published var showDevContainerBanner = false
	@Published private var terminalReloadTokens: [UUID: Int] = [:]

	init() {
		loadProjects()
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
		if project.isDevContainer, let workspacePath = project.devContainerPath, let sshHost = project.sshHost {
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
		selectedProject = project
		showDevContainerBanner = false
		if project?.sshHost != nil && !(project?.isDevContainer ?? false) {
			checkForDevContainer()
		}
	}

	/// Select project by index (for Cmd+1-9).
	func selectByIndex(_ index: Int) {
		guard index >= 0, index < projects.count else { return }
		select(projects[index])
	}

	func selectNextProject() {
		guard !projects.isEmpty else { return }
		let currentIndex = indexOfSelected ?? 0
		let nextIndex = (currentIndex + 1) % projects.count
		select(projects[nextIndex])
	}

	func selectPreviousProject() {
		guard !projects.isEmpty else { return }
		let currentIndex = indexOfSelected ?? 0
		let previousIndex = (currentIndex - 1 + projects.count) % projects.count
		select(projects[previousIndex])
	}

	// MARK: - CRUD

	func addProject(name: String? = nil, sshHost: String? = nil) -> Project {
		let baseName = name ?? NSHomeDirectory().components(separatedBy: "/").last ?? "Project"
		let finalName = uniqueName(baseName)
		let project = Project(
			name: finalName,
			sshHost: sshHost
		)
		projects.append(project)
		saveProjects()
		select(project)
		return project
	}

	func deleteProject(_ id: UUID) {
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

		// Kill old persist sessions
		let projShort = String(projects[index].id.uuidString.prefix(8))
		let sessionsDir = "/tmp/belve-shell/sessions"
		if let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) {
			for file in files where file.hasPrefix("belve-\(projShort)") && file.hasSuffix(".sock") {
				let sockPath = (sessionsDir as NSString).appendingPathComponent(file)
				let kill = Process()
				kill.executableURL = URL(fileURLWithPath: "/usr/bin/fuser")
				kill.arguments = ["-k", sockPath]
				try? kill.run()
				kill.waitUntilExit()
				try? FileManager.default.removeItem(atPath: sockPath)
			}
		}

		// Replace with a fresh project (new ID = clean slate for layout, sessions, etc.)
		let newProject = Project(
			name: (path as NSString).lastPathComponent,
			remotePath: path
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
		if let webView = findTerminalWebView(paneId: paneId) {
			webView.window?.makeFirstResponder(webView)
			webView.evaluateJavaScript("terminalFocus(true)", completionHandler: nil)
		}
	}

	private func findTerminalWebView(paneId: String? = nil) -> WKWebView? {
		guard let window = NSApp.keyWindow else { return nil }
		let targetIdentifier = paneId.map { "BelveTerminalWebView:\($0)" }

		func find(_ view: NSView) -> WKWebView? {
			if let v = view as? WKWebView {
				if let targetIdentifier {
					if v.identifier?.rawValue == targetIdentifier { return v }
				} else if v.identifier?.rawValue.hasPrefix("BelveTerminalWebView") == true {
					return v
				}
			}
			for sub in view.subviews {
				if let found = find(sub) { return found }
			}
			return nil
		}
		return find(window.contentView ?? window.contentView!)
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
			projects[index].sshHost = host
			// Only set name to host if no folder name is set yet
			if projects[index].remotePath == nil {
				projects[index].name = host.components(separatedBy: ".").first ?? host
			}
			saveProjects()
			selectedProject = projects[index]
			// Connect via existing terminal
			sendToActiveTerminal("ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -t \(host)\n")
		} else {
			let _ = addProject(name: host.components(separatedBy: ".").first, sshHost: host)
		}
	}

	// MARK: - DevContainer

	func openDevContainer() {
		guard let index = indexOfSelected,
			  projects[index].sshHost != nil,
			  let workspacePath = projects[index].remotePath else {
			NSLog("[Belve] Cannot open DevContainer: no remotePath set. Use Cmd+O first.")
			return
		}
		// Update name from workspace path, recreate with new ID for fresh terminals
		var updated = projects[index]
		updated.devContainerPath = workspacePath
		updated.name = (workspacePath as NSString).lastPathComponent
		replaceWithNewId(at: index, updated: updated)
		// Fetch container image name from host-side devcontainer.json
		if let sshHost = updated.sshHost {
			fetchContainerImageName(sshHost: sshHost, remotePath: workspacePath)
		}
		NSLog("[Belve] DevContainer enabled for \(updated.name)")
	}

	func disconnectSSH() {
		guard let index = indexOfSelected else { return }
		let name = projects[index].name
		var updated = projects[index]
		updated.sshHost = nil
		updated.remotePath = nil
		updated.devContainerPath = nil
		replaceWithNewId(at: index, updated: updated)
		NSLog("[Belve] SSH disconnected for \(name), reverted to local")
	}

	func closeDevContainer() {
		guard let index = indexOfSelected else { return }
		var updated = projects[index]
		updated.devContainerPath = nil
		replaceWithNewId(at: index, updated: updated)
		NSLog("[Belve] DevContainer disabled, reverting to SSH")
	}

	/// Replace a project with a new ID to force terminal recreation.
	/// Old terminal surfaces remain in memory (Ghostty can't free them) but become invisible.
	private func replaceWithNewId(at index: Int, updated: Project) {
		let newProject = Project(
			name: updated.name,
			sshHost: updated.sshHost,
			remotePath: updated.remotePath,
			devContainerPath: updated.devContainerPath,
			containerImageName: updated.containerImageName
		)
		projects[index] = newProject
		saveProjects()
		select(newProject)
	}

	private func fetchContainerImageName(sshHost: String, remotePath: String) {
		let jsonPath = "\(remotePath)/.devcontainer/devcontainer.json"
		DispatchQueue.global().async { [weak self] in
			// Read devcontainer.json directly from SSH host (not inside container)
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
			process.arguments = [
				"-o", "StrictHostKeyChecking=accept-new",
				"-o", "ConnectTimeout=5",
				"-o", "BatchMode=yes",
				"-o", "ControlMaster=auto",
				"-o", "ControlPath=/tmp/belve-ssh-%r@%h:%p",
				"-o", "ControlPersist=600",
				sshHost,
				"cat \(jsonPath)"
			]
			let pipe = Pipe()
			process.standardOutput = pipe
			process.standardError = Pipe()
			try? process.run()
			process.waitUntilExit()
			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			guard !data.isEmpty else { return }

			// Strip JSON comments (// style) before parsing
			let raw = String(data: data, encoding: .utf8) ?? ""
			let stripped = raw.components(separatedBy: "\n")
				.map { line in
					// Remove // comments (simple heuristic, doesn't handle strings)
					if let range = line.range(of: "//") {
						let before = line[line.startIndex..<range.lowerBound]
						// Only strip if not inside a string
						if before.filter({ $0 == "\"" }).count % 2 == 0 {
							return String(before)
						}
					}
					return line
				}
				.joined(separator: "\n")

			guard let jsonData = stripped.data(using: .utf8),
				  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

			// Try "image", then "dockerComposeFile" service name, then "build.dockerfile"
			let imageName: String?
			if let image = json["image"] as? String {
				imageName = image
			} else if let service = json["service"] as? String {
				imageName = service
			} else if let build = json["build"] as? [String: Any], let dockerfile = build["dockerfile"] as? String {
				imageName = "Dockerfile: \(dockerfile)"
			} else {
				imageName = nil
			}

			guard let imageName else { return }

			DispatchQueue.main.async {
				guard let self else { return }
				// Find the project by matching remotePath and DevContainer status
				guard let idx = self.projects.firstIndex(where: { $0.devContainerPath == remotePath }) else { return }
				self.projects[idx].containerImageName = imageName
				self.saveProjects()
				if self.selectedProject?.id == self.projects[idx].id {
					self.selectedProject = self.projects[idx]
				}
				NSLog("[Belve] Container image: \(imageName)")
			}
		}
	}

	private func checkForDevContainer() {
		guard let project = selectedProject,
			  project.sshHost != nil,
			  let remotePath = project.remotePath,
			  !project.isDevContainer else { return }

		let ctx = project.executionContext
		DispatchQueue.global().async { [weak self] in
			let hasDevContainer = ctx.fileExists("\(remotePath)/.devcontainer/devcontainer.json")
				|| ctx.fileExists("\(remotePath)/.devcontainer.json")
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

	private func loadProjects() {
		guard let data = try? Data(contentsOf: Self.projectsFileURL),
			  let decoded = try? JSONDecoder().decode([Project].self, from: data),
			  !decoded.isEmpty else {
			projects = [Project(name: "Project 1")]
			return
		}
		projects = decoded
		selectedProject = decoded.first
	}

	func saveProjects() {
		if let data = try? JSONEncoder().encode(projects) {
			try? data.write(to: Self.projectsFileURL)
		}
	}
}
