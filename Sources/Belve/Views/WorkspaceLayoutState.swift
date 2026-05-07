import SwiftUI

final class ProjectLayoutState: ObservableObject, Codable {
	@Published var commandAreaFraction: CGFloat = 0.65 {
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
	/// Absolute path of the file last opened in the editor for this project.
	/// Restored automatically on project selection.
	@Published var lastOpenedFile: String? = nil {
		didSet { onChanged?() }
	}
	/// Whether the Changes (diff) view is shown instead of the editor.
	@Published var showChanges: Bool = false {
		didSet { onChanged?() }
	}
	/// Preview-area mode: `.editor` shows the file tree + code/markdown editor
	/// (the default), `.browser` swaps that out for a lightweight WKWebView
	/// for debugging forwarded ports and local dev servers.
	@Published var previewMode: PreviewMode = .editor {
		didSet { onChanged?() }
	}
	/// Persisted URL shown in the browser pane. Restored when the user
	/// flips `previewMode` back to `.browser`.
	@Published var browserURL: String = "" {
		didSet { onChanged?() }
	}
	/// Whether the floating browser panel was open when this project was last
	/// active. The window is auto-restored on project select.
	@Published var browserOpen: Bool = false {
		didSet { onChanged?() }
	}
	/// Whether the browser panel was in its shrunk (thumbnail) state.
	@Published var browserThumbnail: Bool = false {
		didSet { onChanged?() }
	}
	/// Last full-size frame of the browser panel (separate from thumbnail
	/// dimensions so shrinking + restoring doesn't lose the user's preferred
	/// size/position).
	@Published var browserFrame: StoredFrame? = nil {
		didSet { onChanged?() }
	}
	/// 仮想 viewport (width, height) — 設定されていれば WKWebView をその論理
	/// サイズで描画し、ウィンドウサイズに合わせて scale で縮小する。
	/// nil = ネイティブ (ウィンドウサイズそのまま)。media query を効かせた
	/// まま小さいウィンドウで広い画面のレイアウトを確認するために使う。
	@Published var browserViewport: StoredViewport? = nil {
		didSet { onChanged?() }
	}
	/// ChangesView の左 tree pane の幅。drag で調整可能、project 単位で永続化。
	@Published var changesTreeWidth: CGFloat = 220 {
		didSet { onChanged?() }
	}
	/// ChangesView の filter (= staged/unstaged/committed のチェックボックス)。
	/// project 単位で永続化して、開き直した時も同じ filter で表示される。
	@Published var diffFilterStaged: Bool = true {
		didSet { onChanged?() }
	}
	@Published var diffFilterUnstaged: Bool = true {
		didSet { onChanged?() }
	}
	@Published var diffFilterCommitted: Bool = false {
		didSet { onChanged?() }
	}

	var onChanged: (() -> Void)?

	init(commandAreaFraction: CGFloat = 0.65, showEditor: Bool = true, showFileTree: Bool = true, fileTreeWidth: CGFloat = 200, lastOpenedFile: String? = nil, previewMode: PreviewMode = .editor, browserURL: String = "") {
		self.commandAreaFraction = commandAreaFraction
		self.showEditor = showEditor
		self.showFileTree = showFileTree
		self.fileTreeWidth = fileTreeWidth
		self.lastOpenedFile = lastOpenedFile
		self.previewMode = previewMode
		self.browserURL = browserURL
	}

	enum CodingKeys: String, CodingKey {
		case commandAreaFraction, showEditor, showFileTree, fileTreeWidth, lastOpenedFile, showChanges, previewMode, browserURL, browserOpen, browserThumbnail, browserFrame, browserViewport
		case changesTreeWidth, diffFilterStaged, diffFilterUnstaged, diffFilterCommitted
	}

	required init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		commandAreaFraction = try container.decodeIfPresent(CGFloat.self, forKey: .commandAreaFraction) ?? 0.5
		showEditor = try container.decodeIfPresent(Bool.self, forKey: .showEditor) ?? true
		showFileTree = try container.decodeIfPresent(Bool.self, forKey: .showFileTree) ?? true
		fileTreeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .fileTreeWidth) ?? 200
		lastOpenedFile = try container.decodeIfPresent(String.self, forKey: .lastOpenedFile)
		showChanges = try container.decodeIfPresent(Bool.self, forKey: .showChanges) ?? false
		previewMode = try container.decodeIfPresent(PreviewMode.self, forKey: .previewMode) ?? .editor
		browserURL = try container.decodeIfPresent(String.self, forKey: .browserURL) ?? ""
		browserOpen = try container.decodeIfPresent(Bool.self, forKey: .browserOpen) ?? false
		browserThumbnail = try container.decodeIfPresent(Bool.self, forKey: .browserThumbnail) ?? false
		browserFrame = try container.decodeIfPresent(StoredFrame.self, forKey: .browserFrame)
		browserViewport = try container.decodeIfPresent(StoredViewport.self, forKey: .browserViewport)
		changesTreeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .changesTreeWidth) ?? 220
		diffFilterStaged = try container.decodeIfPresent(Bool.self, forKey: .diffFilterStaged) ?? true
		diffFilterUnstaged = try container.decodeIfPresent(Bool.self, forKey: .diffFilterUnstaged) ?? true
		diffFilterCommitted = try container.decodeIfPresent(Bool.self, forKey: .diffFilterCommitted) ?? false
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(commandAreaFraction, forKey: .commandAreaFraction)
		try container.encode(showEditor, forKey: .showEditor)
		try container.encode(showFileTree, forKey: .showFileTree)
		try container.encode(fileTreeWidth, forKey: .fileTreeWidth)
		try container.encodeIfPresent(lastOpenedFile, forKey: .lastOpenedFile)
		try container.encode(showChanges, forKey: .showChanges)
		try container.encode(previewMode, forKey: .previewMode)
		try container.encode(browserURL, forKey: .browserURL)
		try container.encode(browserOpen, forKey: .browserOpen)
		try container.encode(browserThumbnail, forKey: .browserThumbnail)
		try container.encodeIfPresent(browserFrame, forKey: .browserFrame)
		try container.encodeIfPresent(browserViewport, forKey: .browserViewport)
		try container.encode(changesTreeWidth, forKey: .changesTreeWidth)
		try container.encode(diffFilterStaged, forKey: .diffFilterStaged)
		try container.encode(diffFilterUnstaged, forKey: .diffFilterUnstaged)
		try container.encode(diffFilterCommitted, forKey: .diffFilterCommitted)
	}
}

/// 仮想 viewport の永続化用 (CGSize は Codable 非対応)。
struct StoredViewport: Codable, Equatable {
	let width: Double
	let height: Double

	init(_ size: CGSize) {
		width = size.width
		height = size.height
	}

	var size: CGSize { CGSize(width: width, height: height) }
}

enum PreviewMode: String, Codable {
	case editor
	case browser
}

/// `NSRect` equivalent that survives JSON encoding. Used for persisting the
/// browser panel's full-size frame across project switches and app restarts.
struct StoredFrame: Codable, Equatable {
	let x: Double
	let y: Double
	let width: Double
	let height: Double

	init(_ rect: CGRect) {
		x = rect.origin.x
		y = rect.origin.y
		width = rect.size.width
		height = rect.size.height
	}

	var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
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
