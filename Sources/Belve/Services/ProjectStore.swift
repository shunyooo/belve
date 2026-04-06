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
		guard let index = indexOfSelected else { return }
		// Create a new Project with same data but new UUID to force view recreation
		let old = projects[index]
		let reloaded = Project(
			id: UUID(),
			name: old.name,
			sshHost: old.sshHost,
			remotePath: old.remotePath,
			devContainerPath: old.devContainerPath
		)
		projects[index] = reloaded
		selectedProject = reloaded
		saveProjects()
		NSLog("[Belve] Reloaded project: \(reloaded.name)")
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
		let project = Project(
			name: name ?? "Project \(projects.count + 1)",
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
		guard let index = indexOfSelected else { return }
		projects[index].remotePath = path
		projects[index].name = (path as NSString).lastPathComponent
		saveProjects()

		// Reset by re-selecting (forces view recreation)
		let updated = projects[index]
		selectedProject = nil
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
			self?.select(updated)
		}
		NSLog("[Belve] Opened folder: \(path)")
	}

	// MARK: - SSH

	func connectSSH(host: String) {
		if let index = indexOfSelected {
			projects[index].sshHost = host
			projects[index].name = host.components(separatedBy: ".").first ?? host
			saveProjects()
			let project = projects[index]
			selectedProject = nil
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
				self?.select(project)
			}
		} else {
			let _ = addProject(name: host.components(separatedBy: ".").first, sshHost: host)
		}
	}

	// MARK: - DevContainer

	func openDevContainer() {
		guard let index = indexOfSelected,
			  projects[index].sshHost != nil else { return }
		let workspacePath = projects[index].remotePath ?? "~"
		projects[index].devContainerPath = workspacePath
		saveProjects()

		let project = projects[index]
		selectedProject = nil
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
			self?.select(project)
		}
		NSLog("[Belve] DevContainer enabled for \(project.name)")
	}

	func disconnectSSH() {
		guard let index = indexOfSelected else { return }
		let name = projects[index].name
		projects[index].sshHost = nil
		projects[index].remotePath = nil
		projects[index].devContainerPath = nil
		saveProjects()
		selectedProject = projects[index]
		NSLog("[Belve] SSH disconnected for \(name), reverted to local")
	}

	func closeDevContainer() {
		guard let index = indexOfSelected else { return }
		projects[index].devContainerPath = nil
		saveProjects()

		let project = projects[index]
		selectedProject = nil
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
			self?.select(project)
		}
		NSLog("[Belve] DevContainer disabled, reverting to SSH")
	}

	private func checkForDevContainer() {
		guard let project = selectedProject,
			  let sshHost = project.sshHost,
			  let remotePath = project.remotePath,
			  !project.isDevContainer else { return }

		DispatchQueue.global().async { [weak self] in
			let hasDevContainer = FileService.fileExists(
				path: "\(remotePath)/.devcontainer/devcontainer.json",
				sshHost: sshHost
			) || FileService.fileExists(
				path: "\(remotePath)/.devcontainer.json",
				sshHost: sshHost
			)
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
