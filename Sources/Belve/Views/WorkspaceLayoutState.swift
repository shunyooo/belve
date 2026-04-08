import SwiftUI

final class ProjectLayoutState: ObservableObject, Codable {
	@Published var commandAreaFraction: CGFloat = 0.5 {
		didSet { onChanged?() }
	}
	@Published var showEditor: Bool = true {
		didSet { onChanged?() }
	}
	@Published var showFileTree: Bool = true {
		didSet { onChanged?() }
	}
	@Published var fileTreeWidth: CGFloat = 200 {
		didSet { onChanged?() }
	}

	var onChanged: (() -> Void)?

	init(commandAreaFraction: CGFloat = 0.5, showEditor: Bool = true, showFileTree: Bool = true, fileTreeWidth: CGFloat = 200) {
		self.commandAreaFraction = commandAreaFraction
		self.showEditor = showEditor
		self.showFileTree = showFileTree
		self.fileTreeWidth = fileTreeWidth
	}

	enum CodingKeys: String, CodingKey {
		case commandAreaFraction, showEditor, showFileTree, fileTreeWidth
	}

	required init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		commandAreaFraction = try container.decodeIfPresent(CGFloat.self, forKey: .commandAreaFraction) ?? 0.5
		showEditor = try container.decodeIfPresent(Bool.self, forKey: .showEditor) ?? true
		showFileTree = try container.decodeIfPresent(Bool.self, forKey: .showFileTree) ?? true
		fileTreeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .fileTreeWidth) ?? 200
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(commandAreaFraction, forKey: .commandAreaFraction)
		try container.encode(showEditor, forKey: .showEditor)
		try container.encode(showFileTree, forKey: .showFileTree)
		try container.encode(fileTreeWidth, forKey: .fileTreeWidth)
	}
}

final class WorkspaceLayoutStateManager: ObservableObject {
	@Published var showSidebar: Bool = true {
		didSet { saveIfNeeded() }
	}
	@Published var sidebarWidth: CGFloat = 200 {
		didSet { saveIfNeeded() }
	}

	private var projectStates: [UUID: ProjectLayoutState] = [:]
	private var isRestoring = false

	private struct PersistedLayoutState: Codable {
		let showSidebar: Bool
		let sidebarWidth: CGFloat
		let projects: [String: ProjectLayoutState]
	}

	private static var saveURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("workspace-layout.json")
	}

	init() {
		load()
	}

	func state(for projectId: UUID) -> ProjectLayoutState {
		if let existing = projectStates[projectId] {
			return existing
		}

		let state = ProjectLayoutState()
		attach(state)
		projectStates[projectId] = state
		saveIfNeeded()
		return state
	}

	private func attach(_ state: ProjectLayoutState) {
		state.onChanged = { [weak self] in
			guard let self else { return }
			self.objectWillChange.send()
			self.saveIfNeeded()
		}
	}

	private func saveIfNeeded() {
		guard !isRestoring else { return }
		save()
	}

	private func save() {
		let persisted = PersistedLayoutState(
			showSidebar: showSidebar,
			sidebarWidth: sidebarWidth,
			projects: projectStates.reduce(into: [:]) { result, pair in
				result[pair.key.uuidString] = pair.value
			}
		)

		if let encoded = try? JSONEncoder().encode(persisted) {
			try? encoded.write(to: Self.saveURL)
		}
	}

	private func load() {
		guard let data = try? Data(contentsOf: Self.saveURL),
			  let persisted = try? JSONDecoder().decode(PersistedLayoutState.self, from: data) else {
			return
		}

		isRestoring = true
		showSidebar = persisted.showSidebar
		sidebarWidth = persisted.sidebarWidth
		projectStates = persisted.projects.reduce(into: [:]) { result, pair in
			guard let projectId = UUID(uuidString: pair.key) else { return }
			attach(pair.value)
			result[projectId] = pair.value
		}
		isRestoring = false
	}
}
