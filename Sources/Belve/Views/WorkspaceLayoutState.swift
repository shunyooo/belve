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
	/// Preview 右カラムのモード: false = ツリー (全ファイルツリー)、
	/// true = 変更 (このプロジェクトの変更ファイルを recency 順に並べた軽量一覧)。
	/// full-panel の `showChanges` (Cmd+Shift+G) とは別物で、editor を隠さず
	/// カラム内でトグルする。project 単位で永続化。
	@Published var fileColumnShowsChanges: Bool = false {
		didSet { onChanged?() }
	}
	/// Preview-area mode: `.editor` shows the file tree + code/markdown editor
	/// (the default), `.browser` swaps that out for a lightweight WKWebView
	/// for debugging forwarded ports and local dev servers.
	@Published var previewMode: PreviewMode = .editor {
		didSet { onChanged?() }
	}
	/// このプロジェクトのフローティングブラウザ窓 (複数)。各窓が独立した
	/// url / frame / viewport / thumbnail / open を持つ。永続化はこの配列が源泉。
	/// 参照型要素なので manager と BrowserView が同一インスタンスを共有する。
	@Published var browserWindows: [BrowserWindowState] = [] {
		didSet { rewireBrowserWindows(); onChanged?() }
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
	/// Preview 側で選択中の git worktree の絶対パス。nil = メイン作業ツリー
	/// (= project.effectivePath の正規経路)。worktree はエフェメラルなので、
	/// 復元時に存在確認して消えていれば nil に戻す (PreviewArea が担当)。
	@Published var selectedWorktreePath: String? = nil {
		didSet { onChanged?() }
	}

	var onChanged: (() -> Void)?

	init(commandAreaFraction: CGFloat = 0.65, showEditor: Bool = true, showFileTree: Bool = true, fileTreeWidth: CGFloat = 200, lastOpenedFile: String? = nil, previewMode: PreviewMode = .editor) {
		self.commandAreaFraction = commandAreaFraction
		self.showEditor = showEditor
		self.showFileTree = showFileTree
		self.fileTreeWidth = fileTreeWidth
		self.lastOpenedFile = lastOpenedFile
		self.previewMode = previewMode
	}

	/// browserWindows 各要素の onChanged を親 (self.onChanged) へ転送する。
	/// 配列の replace/append/remove のたびに呼び直して子の永続化配線を維持する。
	private func rewireBrowserWindows() {
		for w in browserWindows {
			w.onChanged = { [weak self] in self?.onChanged?() }
		}
	}

	enum CodingKeys: String, CodingKey {
		case commandAreaFraction, showEditor, showFileTree, fileTreeWidth, lastOpenedFile, showChanges, previewMode
		// 旧単一ブラウザのキー: decode-only (init(from:) で browserWindows へ 1 回だけ移行)。
		case browserURL, browserOpen, browserThumbnail, browserFrame, browserViewport
		case browserWindows
		case changesTreeWidth, diffFilterStaged, diffFilterUnstaged, diffFilterCommitted
		case fileColumnShowsChanges
		case selectedWorktreePath
	}

	required init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		commandAreaFraction = try container.decodeIfPresent(CGFloat.self, forKey: .commandAreaFraction) ?? 0.5
		showEditor = try container.decodeIfPresent(Bool.self, forKey: .showEditor) ?? true
		showFileTree = try container.decodeIfPresent(Bool.self, forKey: .showFileTree) ?? true
		fileTreeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .fileTreeWidth) ?? 200
		lastOpenedFile = try container.decodeIfPresent(String.self, forKey: .lastOpenedFile)
		showChanges = try container.decodeIfPresent(Bool.self, forKey: .showChanges) ?? false
		fileColumnShowsChanges = try container.decodeIfPresent(Bool.self, forKey: .fileColumnShowsChanges) ?? false
		previewMode = try container.decodeIfPresent(PreviewMode.self, forKey: .previewMode) ?? .editor
		// ブラウザ: 新形式 (配列) があればそれを、無ければ旧単一フィールドから 1 要素へ移行。
		if let windows = try container.decodeIfPresent([BrowserWindowState].self, forKey: .browserWindows) {
			browserWindows = windows
		} else {
			let legacyURL = try container.decodeIfPresent(String.self, forKey: .browserURL) ?? ""
			let legacyOpen = try container.decodeIfPresent(Bool.self, forKey: .browserOpen) ?? false
			let legacyThumb = try container.decodeIfPresent(Bool.self, forKey: .browserThumbnail) ?? false
			let legacyFrame = try container.decodeIfPresent(StoredFrame.self, forKey: .browserFrame)
			let legacyViewport = try container.decodeIfPresent(StoredViewport.self, forKey: .browserViewport)
			if !legacyURL.isEmpty || legacyOpen || legacyFrame != nil || legacyViewport != nil {
				browserWindows = [BrowserWindowState(
					url: legacyURL, frame: legacyFrame, viewport: legacyViewport,
					thumbnail: legacyThumb, open: legacyOpen
				)]
			} else {
				browserWindows = []
			}
		}
		rewireBrowserWindows()
		changesTreeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .changesTreeWidth) ?? 220
		diffFilterStaged = try container.decodeIfPresent(Bool.self, forKey: .diffFilterStaged) ?? true
		diffFilterUnstaged = try container.decodeIfPresent(Bool.self, forKey: .diffFilterUnstaged) ?? true
		diffFilterCommitted = try container.decodeIfPresent(Bool.self, forKey: .diffFilterCommitted) ?? false
		selectedWorktreePath = try container.decodeIfPresent(String.self, forKey: .selectedWorktreePath)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(commandAreaFraction, forKey: .commandAreaFraction)
		try container.encode(showEditor, forKey: .showEditor)
		try container.encode(showFileTree, forKey: .showFileTree)
		try container.encode(fileTreeWidth, forKey: .fileTreeWidth)
		try container.encodeIfPresent(lastOpenedFile, forKey: .lastOpenedFile)
		try container.encode(showChanges, forKey: .showChanges)
		try container.encode(fileColumnShowsChanges, forKey: .fileColumnShowsChanges)
		try container.encode(previewMode, forKey: .previewMode)
		// 新形式のみ書き出す (旧 browser* キーは移行後に消える = dead field を残さない)。
		try container.encode(browserWindows, forKey: .browserWindows)
		try container.encode(changesTreeWidth, forKey: .changesTreeWidth)
		try container.encode(diffFilterStaged, forKey: .diffFilterStaged)
		try container.encode(diffFilterUnstaged, forKey: .diffFilterUnstaged)
		try container.encode(diffFilterCommitted, forKey: .diffFilterCommitted)
		try container.encodeIfPresent(selectedWorktreePath, forKey: .selectedWorktreePath)
	}
}

/// 1 個のフローティングブラウザ窓の永続状態。`ProjectLayoutState.browserWindows`
/// の要素。参照型にして BrowserWindowManager と BrowserView が同一インスタンスを
/// 共有し、編集がそのまま永続化 + 閉じ/再開を跨いで残るようにする
/// (ProjectLayoutState と同じ思想)。
final class BrowserWindowState: ObservableObject, Codable, Identifiable {
	let id: UUID
	@Published var url: String { didSet { onChanged?() } }
	/// フルサイズ時の frame (thumbnail 縮小で失わないよう別持ち)。
	@Published var frame: StoredFrame? { didSet { onChanged?() } }
	/// 仮想 viewport。nil = ネイティブ。
	@Published var viewport: StoredViewport? { didSet { onChanged?() } }
	/// thumbnail (右下に縮小退避) 状態か。
	@Published var thumbnail: Bool { didSet { onChanged?() } }
	/// 前回アクティブ時に画面に出ていたか (project 復帰時に再オープンする対象)。
	@Published var open: Bool { didSet { onChanged?() } }

	/// 親 ProjectLayoutState.onChanged へ転送する (永続化トリガ)。親が rewire で配線。
	var onChanged: (() -> Void)?

	init(id: UUID = UUID(), url: String = "", frame: StoredFrame? = nil,
	     viewport: StoredViewport? = nil, thumbnail: Bool = false, open: Bool = true) {
		self.id = id
		self.url = url
		self.frame = frame
		self.viewport = viewport
		self.thumbnail = thumbnail
		self.open = open
	}

	enum CodingKeys: String, CodingKey { case id, url, frame, viewport, thumbnail, open }

	required init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
		url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
		frame = try c.decodeIfPresent(StoredFrame.self, forKey: .frame)
		viewport = try c.decodeIfPresent(StoredViewport.self, forKey: .viewport)
		thumbnail = try c.decodeIfPresent(Bool.self, forKey: .thumbnail) ?? false
		open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? true
	}

	func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(id, forKey: .id)
		try c.encode(url, forKey: .url)
		try c.encodeIfPresent(frame, forKey: .frame)
		try c.encodeIfPresent(viewport, forKey: .viewport)
		try c.encode(thumbnail, forKey: .thumbnail)
		try c.encode(open, forKey: .open)
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
