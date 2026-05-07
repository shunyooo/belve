import Foundation

/// Per-project ProjectView 一覧と active view ID を管理 + 永続化する。
///
/// 永続化:
/// - `views.json`: { "projects": [{ projectId, activeViewId, views: [{ id, name }] }] }
///
/// 起動時 migration (Phase 1):
/// - `views.json` 不在で `pane-layouts.json` が存在 → 各 projectId に対して 1 view
///   "main" (id == projectId) を生成して `views.json` を新規書き出し
/// - 既存の `pane-layouts.json` / `workspace-layout.json` は **触らない** (Phase 1
///   は behavior 不変なので、state 管理は引き続き旧キー = projectId で動かす)
/// - Phase 2 で UI 側を view-id 化する際に旧 file の bak 化 + キー再構成を行う
///
/// Threading: main actor から触る前提 (= ProjectStore と同じ流儀)。
@MainActor
final class ProjectViewStore: ObservableObject {
	static let shared = ProjectViewStore()

	/// projectId → views (順序維持)
	@Published private(set) var viewsByProject: [UUID: [ProjectView]] = [:]
	/// projectId → 現在アクティブな view id
	@Published private(set) var activeViewIdByProject: [UUID: UUID] = [:]

	private var pendingSaveTask: DispatchWorkItem?
	private let saveDebounce: TimeInterval = 0.2

	private init() {
		load()
	}

	// MARK: - Public API

	/// 指定 project の view 一覧。順序付き。Phase 1 では常に 1 件 ("main")。
	func views(for projectId: UUID) -> [ProjectView] {
		viewsByProject[projectId] ?? []
	}

	/// 指定 project の active view (= sidebar で選択されてる view)。Phase 1 では
	/// 常に "main"。view が無ければ自動生成して返す (= project が新規作成された
	/// 時に呼ばれた場合)。
	func activeView(for projectId: UUID) -> ProjectView {
		ensureMainView(for: projectId)
		let activeId = activeViewIdByProject[projectId]!
		let list = viewsByProject[projectId]!
		return list.first(where: { $0.id == activeId }) ?? list[0]
	}

	/// Project 新規作成時に呼ぶ。既に view があれば no-op。Phase 1 では "main"
	/// 1 件を生成して active に設定。
	func ensureMainView(for projectId: UUID) {
		if viewsByProject[projectId]?.isEmpty == false { return }
		let main = ProjectView.main(for: projectId)
		viewsByProject[projectId] = [main]
		activeViewIdByProject[projectId] = main.id
		scheduleSave()
	}

	/// Project 削除時に呼ぶ。当該 project の全 view 情報を破棄。
	func teardown(projectId: UUID) {
		viewsByProject.removeValue(forKey: projectId)
		activeViewIdByProject.removeValue(forKey: projectId)
		scheduleSave()
	}

	/// 指定 view を active に設定。Sidebar で view row を click した時に呼ぶ。
	/// projectId は view が属する project (= 不一致なら no-op)。
	func setActiveView(_ viewId: UUID, for projectId: UUID) {
		guard let list = viewsByProject[projectId], list.contains(where: { $0.id == viewId }) else { return }
		guard activeViewIdByProject[projectId] != viewId else { return }
		activeViewIdByProject[projectId] = viewId
		scheduleSave()
	}

	/// 新 view を生成して active に設定。返り値は生成した view。
	/// 名前が重複してたら "View 2", "View 3"… で連番付与。
	@discardableResult
	func createView(for projectId: UUID, name: String? = nil) -> ProjectView {
		ensureMainView(for: projectId)
		let baseName = name ?? "View"
		let existing = Set((viewsByProject[projectId] ?? []).map(\.name))
		let finalName: String
		if !existing.contains(baseName) {
			finalName = baseName
		} else {
			var i = 2
			while existing.contains("\(baseName) \(i)") { i += 1 }
			finalName = "\(baseName) \(i)"
		}
		let newView = ProjectView(id: UUID(), projectId: projectId, name: finalName)
		viewsByProject[projectId, default: []].append(newView)
		activeViewIdByProject[projectId] = newView.id
		// CommandAreaStateManager.state(for:) と同様、view 作成は即時 persist。
		// debounce 中に Belve quit/crash したら view が消滅するため。
		save()
		return newView
	}

	/// View を削除。最後の 1 view は削除不可 (= 必ず "main" 相当が残る)。
	/// active view を削除した場合は先頭 view を新 active に。
	func deleteView(_ viewId: UUID, from projectId: UUID) {
		guard var list = viewsByProject[projectId], list.count > 1 else { return }
		guard let idx = list.firstIndex(where: { $0.id == viewId }) else { return }
		list.remove(at: idx)
		viewsByProject[projectId] = list
		if activeViewIdByProject[projectId] == viewId {
			activeViewIdByProject[projectId] = list.first?.id
		}
		scheduleSave()
	}

	/// View の rename。Sidebar の inline edit から呼ぶ。
	func renameView(_ viewId: UUID, in projectId: UUID, to newName: String) {
		guard var list = viewsByProject[projectId],
		      let idx = list.firstIndex(where: { $0.id == viewId }) else { return }
		list[idx].name = newName
		viewsByProject[projectId] = list
		scheduleSave()
	}

	// MARK: - Persistence

	private static var saveURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("views.json")
	}

	private static var paneLayoutsURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return appSupport.appendingPathComponent("Belve").appendingPathComponent("pane-layouts.json")
	}

	private struct PersistedProject: Codable {
		let projectId: UUID
		let activeViewId: UUID
		let views: [ProjectView]
	}

	private struct Persisted: Codable {
		let projects: [PersistedProject]
	}

	private func scheduleSave() {
		pendingSaveTask?.cancel()
		let task = DispatchWorkItem { [weak self] in
			Task { @MainActor in self?.save() }
		}
		pendingSaveTask = task
		DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounce, execute: task)
	}

	private func save() {
		let projects = viewsByProject.compactMap { (projectId, views) -> PersistedProject? in
			guard let activeId = activeViewIdByProject[projectId] else { return nil }
			return PersistedProject(projectId: projectId, activeViewId: activeId, views: views)
		}
		let persisted = Persisted(projects: projects)
		guard let encoded = try? JSONEncoder().encode(persisted) else { return }
		try? encoded.write(to: Self.saveURL)
	}

	private func load() {
		if let data = try? Data(contentsOf: Self.saveURL),
		   let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
			for entry in persisted.projects {
				viewsByProject[entry.projectId] = entry.views
				activeViewIdByProject[entry.projectId] = entry.activeViewId
			}
			NSLog("[Belve] Loaded views.json for \(persisted.projects.count) projects")
			return
		}
		// Migration: views.json が無いので、pane-layouts.json から projectId を
		// 拾って 1 view "main" を生成する。
		migrateFromLegacy()
	}

	private func migrateFromLegacy() {
		guard let data = try? Data(contentsOf: Self.paneLayoutsURL),
		      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			NSLog("[Belve] views.json migration: no pane-layouts.json found, starting fresh")
			return
		}
		for key in raw.keys {
			guard let projectId = UUID(uuidString: key) else { continue }
			let main = ProjectView.main(for: projectId)
			viewsByProject[projectId] = [main]
			activeViewIdByProject[projectId] = main.id
		}
		NSLog("[Belve] views.json migration: created 1 'main' view for \(viewsByProject.count) projects")
		save()
	}
}
