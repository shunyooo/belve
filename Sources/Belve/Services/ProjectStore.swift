import Foundation
import SwiftUI

/// Manages project lifecycle: CRUD, persistence, selection, and state reset.
/// Single source of truth for project state — all project mutations go through here.
class ProjectStore: ObservableObject {
	@Published var projects: [Project] = []
	@Published var selectedProject: Project?
	@Published var showDevContainerBanner = false

	init() {
		loadProjects()
	}

	// MARK: - Reload

	/// Reload the current project (re-create terminal, file tree, etc.)
	/// Uses ID change to force SwiftUI view recreation without nil transition.
	func reloadCurrentProject() {
		// Cannot safely destroy Ghostty surfaces — just log for now
		// TODO: Implement safe surface re-creation
		NSLog("[Belve] Reload not yet supported (Ghostty surface lifecycle)")
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
		projects[index].remotePath = path
		projects[index].name = (path as NSString).lastPathComponent
		saveProjects()
		selectedProject = projects[index]
		// Send cd to active terminal
		let cdPath = path.hasPrefix("~") ? path : "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
		// Small delay to let palette close, then send cd and refocus terminal
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
			sendToActiveTerminal(" cd \(cdPath)\n")
			refocusTerminal()
		}
		NSLog("[Belve] Opened folder: \(path)")
	}

	/// Send text to the currently focused GhosttyTerminalNSView
	func sendToActiveTerminal(_ text: String) {
		findTerminalView()?.sendText(text)
	}

	/// Refocus the terminal view after palette/dialog closes
	func refocusTerminal() {
		if let tv = findTerminalView() {
			tv.window?.makeFirstResponder(tv)
		}
	}

	private func findTerminalView() -> GhosttyTerminalNSView? {
		guard let window = NSApp.keyWindow else { return nil }
		func find(_ view: NSView) -> GhosttyTerminalNSView? {
			if let v = view as? GhosttyTerminalNSView { return v }
			for sub in view.subviews {
				if let found = find(sub) { return found }
			}
			return nil
		}
		return find(window.contentView ?? window.contentView!)
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
		// Recreate project with new ID to get fresh terminal sessions
		var updated = projects[index]
		updated.devContainerPath = workspacePath
		replaceWithNewId(at: index, updated: updated)
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
			devContainerPath: updated.devContainerPath
		)
		projects[index] = newProject
		saveProjects()
		select(newProject)
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
