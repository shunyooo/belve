import SwiftUI

/// A single reversible file operation
enum FileTreeUndoEntry {
	case delete(originalPath: String, trashedURL: URL)
	case rename(oldPath: String, newPath: String)
	case move(fromPath: String, toPath: String)
}

/// An action that groups one or more entries (e.g. batch delete = 1 action)
struct FileTreeUndoAction {
	let label: String
	let entries: [FileTreeUndoEntry]
}

class FileTreeState: ObservableObject {
	@Published var items: [FileItem] = []
	@Published var expandedPaths: Set<String> = []
	@Published var childrenCache: [String: [FileItem]] = [:]
	@Published var focusedPath: String?
	@Published var isRootLoading = false
	@Published var loadingDirectories: Set<String> = []
	@Published var ignoredPaths: Set<String> = []

	// Multi-selection
	@Published var selectedPaths: Set<String> = []

	// Double-click detection
	var lastClickedPath: String?
	var lastClickTime: Date = .distantPast

	// Rename
	@Published var renamingPath: String?
	@Published var renamingText: String = ""

	// Delete
	@Published var showDeleteConfirmation = false
	@Published var pendingDeletePaths: [String] = []

	// Undo
	var undoStack: [FileTreeUndoAction] = []
	private let undoStackLimit = 20

	// Status toast
	@Published var statusMessage: String?

	func showStatus(_ message: String) {
		statusMessage = message
	}

	func clearStatus() {
		statusMessage = nil
	}

	func loadRoot(project: Project, rootPath: String, completion: (() -> Void)? = nil) {
		isRootLoading = true
		DispatchQueue.global().async {
			let result = project.provider.listDirectory(rootPath)
			DispatchQueue.main.async {
				self.items = result
				self.isRootLoading = false
				if self.focusedPath == nil {
					self.focusedPath = result.first?.path
				}
				completion?()
			}
			// Check gitignore asynchronously (non-blocking)
			let ignored = project.provider.gitCheckIgnore(rootPath, paths: result.map(\.name))
			if !ignored.isEmpty {
				DispatchQueue.main.async {
					for item in result where ignored.contains(item.name) {
						self.ignoredPaths.insert(item.path)
					}
				}
			}
		}
	}

	/// Refresh root + expanded directories only (lightweight)
	func refreshVisible(project: Project, rootPath: String) {
		DispatchQueue.global().async {
			let rootItems = project.provider.listDirectory(rootPath)
			// Refresh expanded directories
			var updatedCache: [String: [FileItem]] = [:]
			for path in self.expandedPaths {
				updatedCache[path] = project.provider.listDirectory(path)
			}
			DispatchQueue.main.async {
				// 差分が無ければ書き戻さない。SwiftUI は配列 reassign を「全行更新」
				// として扱って ForEach を再評価するので、値が同じでも各行が
				// 再描画されてちらつく。Equatable diff でガードする。
				if self.items != rootItems {
					self.items = rootItems
				}
				for (path, children) in updatedCache {
					if self.childrenCache[path] != children {
						self.childrenCache[path] = children
					}
				}
			}
		}
	}

	/// Compact single-child directory chains: "Sources" → "Sources/Belve" if Belve is the only child
	private func compactFolders(_ items: [FileItem], project: Project, baseName: String?) -> [FileItem] {
		let dirs = items.filter(\.isDirectory)
		let files = items.filter { !$0.isDirectory }

		// Only compact if there's exactly one directory and no files
		if dirs.count == 1 && files.isEmpty {
			let dir = dirs[0]
			let compactedName = baseName.map { $0 + "/" + dir.name } ?? dir.name
			// Check deeper
			let subChildren = project.provider.listDirectory(dir.path)
			let subDirs = subChildren.filter(\.isDirectory)
			let subFiles = subChildren.filter { !$0.isDirectory }
			if subDirs.count == 1 && subFiles.isEmpty {
				// Continue compacting
				return compactFolders(subChildren, project: project, baseName: compactedName)
			}
			// End of chain: return the final directory with compacted name
			var compactedItem = dir
			compactedItem.compactName = compactedName
			// Pre-cache children
			DispatchQueue.main.async {
				self.childrenCache[dir.path] = subChildren
			}
			return [compactedItem]
		}

		// No compaction possible: apply baseName if we were mid-chain
		return items
	}

	/// Get flat list of visible items for keyboard navigation
	func visibleItems() -> [FileItem] {
		var result: [FileItem] = []
		collectVisible(items: items, into: &result)
		return result
	}

	private func collectVisible(items: [FileItem], into result: inout [FileItem]) {
		for item in items {
			result.append(item)
			if item.isDirectory, expandedPaths.contains(item.path),
			   let children = childrenCache[item.path] {
				collectVisible(items: children, into: &result)
			}
		}
	}

	func moveFocusUp() {
		let visible = visibleItems()
		guard let current = focusedPath,
			  let idx = visible.firstIndex(where: { $0.path == current }),
			  idx > 0 else {
			focusedPath = visibleItems().first?.path
			return
		}
		focusedPath = visible[idx - 1].path
	}

	func moveFocusDown() {
		let visible = visibleItems()
		guard let current = focusedPath,
			  let idx = visible.firstIndex(where: { $0.path == current }),
			  idx < visible.count - 1 else {
			focusedPath = visibleItems().first?.path
			return
		}
		focusedPath = visible[idx + 1].path
	}

	func toggle(path: String, project: Project) {
		if expandedPaths.contains(path) {
			// Collapse: also collapse any compact-expanded children
			expandedPaths.remove(path)
			if let children = childrenCache[path] {
				for child in children where child.compactName != nil && child.isDirectory {
					expandedPaths.remove(child.path)
				}
			}
		} else {
			expandedPaths.insert(path)
			if childrenCache[path] == nil {
				loadingDirectories.insert(path)
				let rootPath = project.effectivePath
				DispatchQueue.global().async {
					var children = project.provider.listDirectory(path)
					// Compact folders: if only child is a single directory, merge names
					children = self.compactFolders(children, project: project, baseName: nil)
					DispatchQueue.main.async {
						self.loadingDirectories.remove(path)
						self.childrenCache[path] = children
						// Auto-expand compacted directories
						for child in children where child.compactName != nil && child.isDirectory {
							self.expandedPaths.insert(child.path)
						}
					}
					// Check gitignore asynchronously
					let relativePaths = children.map { item -> String in
						if item.path.hasPrefix(rootPath) {
							return String(item.path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
						}
						return item.name
					}
					let ignored = project.provider.gitCheckIgnore(rootPath, paths: relativePaths)
					if !ignored.isEmpty {
						DispatchQueue.main.async {
							for (item, relPath) in zip(children, relativePaths) where ignored.contains(relPath) {
								self.ignoredPaths.insert(item.path)
							}
						}
					}
				}
			}
		}
	}

	// MARK: - Selection

	func selectSingle(_ path: String) {
		selectedPaths = []
		focusedPath = path
	}

	func toggleSelection(_ path: String) {
		if selectedPaths.contains(path) {
			selectedPaths.remove(path)
		} else {
			selectedPaths.insert(path)
		}
		focusedPath = path
	}

	func selectRange(to path: String) {
		let visible = visibleItems()
		guard let anchorPath = focusedPath,
			  let anchorIdx = visible.firstIndex(where: { $0.path == anchorPath }),
			  let targetIdx = visible.firstIndex(where: { $0.path == path }) else {
			selectSingle(path)
			return
		}
		let range = min(anchorIdx, targetIdx)...max(anchorIdx, targetIdx)
		selectedPaths = Set(visible[range].map(\.path))
	}

	/// Returns paths to operate on: selectedPaths if non-empty, otherwise focusedPath
	func effectiveSelection() -> [String] {
		if !selectedPaths.isEmpty {
			return Array(selectedPaths)
		}
		if let focused = focusedPath {
			return [focused]
		}
		return []
	}

	// MARK: - Rename

	func startRename() {
		guard let path = focusedPath else { return }
		let visible = visibleItems()
		guard let item = visible.first(where: { $0.path == path }) else { return }
		renamingPath = path
		renamingText = item.name
	}

	func commitRename(project: Project) {
		guard let oldPath = renamingPath, !renamingText.isEmpty else {
			cancelRename()
			return
		}
		let parentDir = (oldPath as NSString).deletingLastPathComponent
		let newPath = (parentDir as NSString).appendingPathComponent(renamingText)

		guard newPath != oldPath else {
			cancelRename()
			return
		}

		let ctx = project.provider
		DispatchQueue.global().async {
			let success = ctx.moveItem(from: oldPath, to: newPath)
			DispatchQueue.main.async {
				if success {
					let oldName = (oldPath as NSString).lastPathComponent
					self.pushUndo(FileTreeUndoAction(
						label: "Rename \(oldName)",
						entries: [.rename(oldPath: oldPath, newPath: newPath)]
					))
					self.focusedPath = newPath
					self.selectedPaths = []
					self.refreshParent(of: oldPath, project: project)
				}
				self.renamingPath = nil
				self.renamingText = ""
			}
		}
	}

	func cancelRename() {
		renamingPath = nil
		renamingText = ""
	}

	// MARK: - Delete

	func requestDelete(project: Project) {
		let paths = effectiveSelection()
		guard !paths.isEmpty else { return }
		requestDelete(paths: paths, project: project)
	}

	/// 明示的に paths を指定する版 (= 右クリックメニューから 1 ファイル削除など)。
	func requestDelete(paths: [String], project: Project) {
		guard !paths.isEmpty else { return }
		let names = paths.map { ($0 as NSString).lastPathComponent }
		showStatus("Deleting \(names.joined(separator: ", "))...")
		pendingDeletePaths = paths
		confirmDelete(project: project)
	}

	func confirmDelete(project: Project) {
		let pathsToDelete = pendingDeletePaths
		pendingDeletePaths = []

		let ctx = project.provider
		DispatchQueue.global().async {
			var deletedPaths: [String] = []
			var undoEntries: [FileTreeUndoEntry] = []
			for path in pathsToDelete {
				let (success, trashedURL) = ctx.deleteItem(path)
				if success {
					deletedPaths.append(path)
					if let url = trashedURL {
						undoEntries.append(.delete(originalPath: path, trashedURL: url))
					}
				}
			}
			if !undoEntries.isEmpty {
				let names = deletedPaths.map { ($0 as NSString).lastPathComponent }
				let action = FileTreeUndoAction(label: "Delete \(names.joined(separator: ", "))", entries: undoEntries)
				DispatchQueue.main.async {
					self.pushUndo(action)
				}
			}

			// Refresh unique parent directories
			let parentDirs = Set(deletedPaths.map { ($0 as NSString).deletingLastPathComponent })
			DispatchQueue.main.async {
				self.selectedPaths = []
				if let focused = self.focusedPath, deletedPaths.contains(focused) {
					self.focusedPath = nil
				}
				for parent in parentDirs {
					self.refreshParent(ofChild: parent, project: project)
				}
				self.clearStatus()
				// Notify PreviewArea if open file was deleted
				NotificationCenter.default.post(
					name: .belveFileDeleted,
					object: deletedPaths
				)
			}
		}
	}

	// MARK: - Undo

	private func pushUndo(_ action: FileTreeUndoAction) {
		undoStack.append(action)
		if undoStack.count > undoStackLimit {
			undoStack.removeFirst()
		}
	}

	func performUndo(project: Project) {
		guard let action = undoStack.popLast() else { return }

		showStatus("Undoing: \(action.label)...")
		let ctx = project.provider

		DispatchQueue.global().async {
			var affectedPaths: [String] = []

			for entry in action.entries {
				switch entry {
				case .delete(let originalPath, let trashedURL):
					var success = false
					if trashedURL.scheme == "belve-remote", let fragment = trashedURL.fragment {
						let trashPath = fragment.removingPercentEncoding ?? fragment
						success = ctx.moveItem(from: trashPath, to: originalPath)
					} else {
						do {
							try FileManager.default.moveItem(at: trashedURL, to: URL(fileURLWithPath: originalPath))
							success = true
						} catch {
							NSLog("[Belve] Undo delete failed: \(error)")
						}
					}
					if success { affectedPaths.append(originalPath) }

				case .rename(let oldPath, let newPath):
					if ctx.moveItem(from: newPath, to: oldPath) {
						affectedPaths.append(oldPath)
						affectedPaths.append(newPath)
					}

				case .move(let fromPath, let toPath):
					if ctx.moveItem(from: toPath, to: fromPath) {
						affectedPaths.append(fromPath)
						affectedPaths.append(toPath)
					}
				}
			}

			let parentDirs = Set(affectedPaths.map { ($0 as NSString).deletingLastPathComponent })
			DispatchQueue.main.async {
				for dir in parentDirs {
					self.refreshParent(ofChild: dir, project: project)
				}
				self.focusedPath = affectedPaths.first
				self.clearStatus()
			}
		}
	}

	// MARK: - Refresh

	func refreshParent(of path: String, project: Project) {
		let parentDir = (path as NSString).deletingLastPathComponent
		refreshParent(ofChild: parentDir, project: project)
	}

	func refreshParent(ofChild parentDir: String, project: Project) {
		// Check if parentDir is in the cache (it's an expanded directory)
		if childrenCache[parentDir] != nil {
			loadingDirectories.insert(parentDir)
			DispatchQueue.global().async {
				let children = project.provider.listDirectory(parentDir)
				DispatchQueue.main.async {
					self.loadingDirectories.remove(parentDir)
					self.childrenCache[parentDir] = children
				}
			}
		} else {
			// It might be the root level — reload items
			isRootLoading = true
			DispatchQueue.global().async {
				// Find root path by checking if parentDir matches the root
				// We re-list the parent
				let children = project.provider.listDirectory(parentDir)
				DispatchQueue.main.async {
					self.isRootLoading = false
					// Check if any root item's parent matches
					if let first = self.items.first,
					   (first.path as NSString).deletingLastPathComponent == parentDir {
						self.items = children
					}
				}
			}
		}
	}

	func reveal(path: String, rootPath: String, project: Project) {
		let revealPath = {
			let directories = self.ancestorDirectories(for: path, rootPath: rootPath)
			self.expandAncestors(directories, project: project) {
				self.selectedPaths = [path]
				self.focusedPath = path
			}
		}

		if items.isEmpty {
			loadRoot(project: project, rootPath: rootPath, completion: revealPath)
		} else {
			revealPath()
		}
	}

	private func ancestorDirectories(for path: String, rootPath: String) -> [String] {
		var directories: [String] = []
		var current = (path as NSString).deletingLastPathComponent
		let normalizedRoot = (rootPath as NSString).standardizingPath

		while !current.isEmpty && current != normalizedRoot && current.hasPrefix(normalizedRoot) {
			directories.append(current)
			let parent = (current as NSString).deletingLastPathComponent
			if parent == current { break }
			current = parent
		}

		return directories.reversed()
	}

	private func expandAncestors(_ directories: [String], project: Project, completion: @escaping () -> Void) {
		guard let current = directories.first else {
			completion()
			return
		}

		expandedPaths.insert(current)
		if childrenCache[current] != nil {
			expandAncestors(Array(directories.dropFirst()), project: project, completion: completion)
			return
		}

		loadingDirectories.insert(current)
		DispatchQueue.global().async {
			let children = project.provider.listDirectory(current)
			DispatchQueue.main.async {
				self.loadingDirectories.remove(current)
				self.childrenCache[current] = children
				self.expandAncestors(Array(directories.dropFirst()), project: project, completion: completion)
			}
		}
	}

	// MARK: - Navigation

	func navigateToParent() {
		guard let current = focusedPath else { return }
		let parentDir = (current as NSString).deletingLastPathComponent
		let visible = visibleItems()

		// If the current item is an expanded directory, collapse it first
		if expandedPaths.contains(current) {
			expandedPaths.remove(current)
			return
		}

		// Otherwise, move focus to the parent directory
		if let parentItem = visible.first(where: { $0.path == parentDir }) {
			focusedPath = parentItem.path
		}
	}

	func expandOrMoveToChild(project: Project) {
		guard let current = focusedPath else { return }
		let visible = visibleItems()
		guard let item = visible.first(where: { $0.path == current }) else { return }

		if item.isDirectory {
			if !expandedPaths.contains(current) {
				toggle(path: current, project: project)
			} else {
				// Already expanded — move to first child
				if let children = childrenCache[current], let first = children.first {
					focusedPath = first.path
				}
			}
		}
	}

	// MARK: - New File

	@Published var creatingInPath: String?
	@Published var newFileName: String = ""

	func startCreateFile() {
		// Create in focused directory, or in the parent of focused file
		guard let path = focusedPath else { return }
		let visible = visibleItems()
		guard let item = visible.first(where: { $0.path == path }) else { return }

		if item.isDirectory {
			if !expandedPaths.contains(path) {
				// Will expand when we set creatingInPath
			}
			creatingInPath = path
		} else {
			creatingInPath = (path as NSString).deletingLastPathComponent
		}
		newFileName = ""
	}

	/// 明示的に作成先を指定する版 (= 右クリックメニューから「ここに新規ファイル」)。
	func startCreateFile(in directory: String) {
		creatingInPath = directory
		newFileName = ""
		// 親ディレクトリが折りたたまれてれば展開して入力欄を見えるように。
		if !expandedPaths.contains(directory) {
			expandedPaths.insert(directory)
		}
	}

	func commitCreateFile(project: Project) {
		guard let dir = creatingInPath, !newFileName.isEmpty else {
			cancelCreateFile()
			return
		}
		let newPath = (dir as NSString).appendingPathComponent(newFileName)
		let ctx = project.provider
		DispatchQueue.global().async {
			let success = ctx.createFile(newPath)
			DispatchQueue.main.async {
				if success {
					self.refreshParent(ofChild: dir, project: project)
					self.focusedPath = newPath
					// Ensure parent is expanded
					if !self.expandedPaths.contains(dir) {
						self.expandedPaths.insert(dir)
					}
				}
				self.creatingInPath = nil
				self.newFileName = ""
			}
		}
	}

	func cancelCreateFile() {
		creatingInPath = nil
		newFileName = ""
	}
}

struct FileTreeView: View {
	let project: Project
	let rootPath: String
	let onFileSelect: (String) -> Void
	@ObservedObject var state: FileTreeState
	var gitFileStatus: [String: String] = [:]
	@FocusState private var isTreeFocused: Bool
	// Mirror of isTreeFocused that we mutate inside withAnimation so matchedGeometryEffect
	// can observe the change through normal @State observation (SwiftUI @FocusState bool
	// changes are not reliably treated as animatable state).
	@State private var treeBorderActive: Bool = false

	private var isEditing: Bool {
		state.renamingPath != nil || state.creatingInPath != nil
	}

	var body: some View {
		ScrollViewReader { proxy in
		VStack(alignment: .leading, spacing: 0) {
			if state.isRootLoading {
				FileTreeLoadingLine()
			}

			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					ForEach(state.items) { item in
						FileTreeRow(
							item: item,
							depth: 0,
							state: state,
							project: project,
							rootPath: rootPath,
							onFileSelect: onFileSelect,
							gitFileStatus: gitFileStatus
						)
					}
					// ルート直下に新規ファイル作成中なら最後尾に inline TextField を出す。
					// FileTreeRow は自分の path に対応する row 内にしか TextField を
					// 出さない (= ルートには row が無い) ので、ここで補完する。
					// 「ファイル一覧の末尾に追加される」UX を意識して bottom 配置。
					if state.creatingInPath == rootPath {
						RootCreateFileRow(state: state, project: project)
							.id("__root_create__")
					}
					// Background catcher for "new file in root" context menu.
					// Fills remaining vertical space so right-click on the empty
					// area below the last row hits this view (and not a row).
					Color.clear
						.frame(minHeight: 80)
						.contentShape(Rectangle())
						.contextMenu {
							Button("New File") {
								state.startCreateFile(in: rootPath)
							}
						}
				}
				.padding(.vertical, 4)
			}
			.background(Theme.surface)
			.onChange(of: state.creatingInPath) { _, newPath in
				// 新規作成 trigger 時に対象 row まで自動 scroll。
				guard let p = newPath else { return }
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
					withAnimation(.easeOut(duration: 0.15)) {
						proxy.scrollTo(p == rootPath ? "__root_create__" : p, anchor: .center)
					}
				}
			}
			.overlay(FocusBorderOverlay(isActive: treeBorderActive))
			// Drag-and-drop upload from Finder — drops land in the project root.
			.onDrop(of: [.fileURL], isTargeted: nil) { providers in
				handleFileDrop(providers: providers, destination: rootPath)
				return true
			}
			// `.focusable()` (default — [.activate, .edit]) is required for onKeyPress
			// handlers to fire while focused. Stale focus from the editor/terminal
			// side is cleared by the belveEditorWebViewDidFocus / belveTerminalFocused
			// observers below.
			.focusable()
			.focusEffectDisabled()
			.focused($isTreeFocused)
			.onChange(of: state.focusedPath) {
				if let path = state.focusedPath {
					withAnimation(.easeInOut(duration: 0.15)) {
						proxy.scrollTo(path, anchor: nil)
					}
				}
			}
			.onChange(of: isTreeFocused) { _, nowFocused in
				if nowFocused {
					NotificationCenter.default.post(name: .belveFileTreeFocused, object: nil)
				}
				withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)) {
					treeBorderActive = nowFocused
				}
			}
			.onKeyPress(.upArrow) {
				guard !isEditing else { return .ignored }
				state.moveFocusUp()
				return .handled
			}
			.onKeyPress(.downArrow) {
				guard !isEditing else { return .ignored }
				state.moveFocusDown()
				return .handled
			}
			.onKeyPress(.rightArrow) {
				guard !isEditing else { return .ignored }
				state.expandOrMoveToChild(project: project)
				return .handled
			}
			.onKeyPress(.leftArrow) {
				guard !isEditing else { return .ignored }
				state.navigateToParent()
				return .handled
			}
			.onKeyPress(.return) {
				guard !isEditing else { return .ignored }
				if let path = state.focusedPath {
					let visible = state.visibleItems()
					if let item = visible.first(where: { $0.path == path }) {
						if item.isDirectory {
							state.toggle(path: path, project: project)
						} else {
							onFileSelect(path)
						}
					}
				}
				return .handled
			}
			.onKeyPress(.space) {
				guard !isEditing else { return .ignored }
				if let path = state.focusedPath {
					state.toggleSelection(path)
				}
				return .handled
			}
			.onKeyPress(.delete) {
				guard !isEditing else { return .ignored }
				state.requestDelete(project: project)
				return .handled
			}
			.onKeyPress(characters: CharacterSet(charactersIn: "\u{7F}"), phases: .down) { press in
				guard !isEditing, press.modifiers.contains(.command) else { return .ignored }
				state.requestDelete(project: project)
				return .handled
			}
			.onKeyPress(characters: CharacterSet(charactersIn: "z"), phases: .down) { press in
				guard !isEditing, press.modifiers.contains(.command) else { return .ignored }
				state.performUndo(project: project)
				return .handled
			}
			.onKeyPress(characters: CharacterSet(charactersIn: "e"), phases: .down) { press in
				guard !isEditing, press.modifiers.contains(.command) else { return .ignored }
				if press.modifiers.contains(.shift) {
					NotificationCenter.default.post(name: .belveToggleFileTree, object: nil)
				} else {
					NotificationCenter.default.post(name: .belveToggleEditor, object: nil)
				}
				return .handled
			}
			.onKeyPress(characters: CharacterSet(charactersIn: "\\"), phases: .down) { press in
				guard !isEditing, press.modifiers.contains(.command) else { return .ignored }
				NotificationCenter.default.post(name: .belveToggleSidebar, object: nil)
				return .handled
			}
			.onKeyPress(characters: CharacterSet(charactersIn: "'"), phases: .down) { press in
				guard !isEditing, press.modifiers.contains(.command) else { return .ignored }
				NotificationCenter.default.post(name: .belveFocusNextPane, object: nil)
				return .handled
			}
			.onKeyPress(characters: CharacterSet(charactersIn: ";"), phases: .down) { press in
				guard !isEditing, press.modifiers.contains(.command) else { return .ignored }
				NotificationCenter.default.post(name: .belveFocusPreviousPane, object: nil)
				return .handled
			}
			.onKeyPress(KeyEquivalent(Character(UnicodeScalar(0xF705)!))) {
				guard !isEditing else { return .ignored }
				state.startRename()
				return .handled
			}
			.onAppear {
				if state.items.isEmpty {
					state.loadRoot(project: project, rootPath: rootPath)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: .belveFocusFileTree)) { notif in
				guard let projectId = notif.userInfo?["projectId"] as? UUID,
					  projectId == project.id else { return }
				isTreeFocused = true
				if state.focusedPath == nil {
					state.focusedPath = state.visibleItems().first?.path
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: .belveEditorWebViewDidFocus)) { _ in
				if isTreeFocused { isTreeFocused = false }
			}
			.onReceive(NotificationCenter.default.publisher(for: .belveTerminalFocused)) { _ in
				if isTreeFocused { isTreeFocused = false }
			}
			.onReceive(NotificationCenter.default.publisher(for: .belveRevealFileInTree)) { notif in
				guard let projectId = notif.userInfo?["projectId"] as? UUID,
					  projectId == project.id,
					  let path = notif.userInfo?["path"] as? String else { return }
				state.reveal(path: path, rootPath: rootPath, project: project)
			}
		}
		} // ScrollViewReader
		.overlay(alignment: .bottom) {
			if let msg = state.statusMessage {
				Text(msg)
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(.white)
					.padding(.horizontal, 10)
					.padding(.vertical, 5)
					.background(
						RoundedRectangle(cornerRadius: 6)
							.fill(Color.black.opacity(0.75))
					)
					.padding(.bottom, 8)
					.transition(.move(edge: .bottom).combined(with: .opacity))
					.animation(.easeOut(duration: 0.15), value: state.statusMessage)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveUndo)) { _ in
			state.performUndo(project: project)
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveRefreshFileTree)) { _ in
			state.refreshVisible(project: project, rootPath: rootPath)
		}
	}

	private func handleFileDrop(providers: [NSItemProvider], destination: String) {
		let provider = project.provider
		for item in providers {
			_ = item.loadObject(ofClass: URL.self) { url, _ in
				guard let url else { return }
				let destPath = (destination as NSString).appendingPathComponent(url.lastPathComponent)
				DispatchQueue.global(qos: .userInitiated).async {
					let ok = provider.uploadFile(localURL: url, to: destPath)
					DispatchQueue.main.async {
						if ok {
							state.refreshVisible(project: project, rootPath: rootPath)
						} else {
							NSLog("[Belve] upload failed: \(url.lastPathComponent) -> \(destPath)")
						}
					}
				}
			}
		}
	}
}

/// ルート直下に新規ファイル作成中だけ表示される TextField row。
/// 通常の FileTreeRow はディレクトリ row 内に TextField を埋め込む形だが、
/// ルートには対応する row が無い (= 子要素が直接トップレベルに並ぶ構造) ため、
/// 別 view で補う。
private struct RootCreateFileRow: View {
	@ObservedObject var state: FileTreeState
	let project: Project
	@FocusState private var focused: Bool

	var body: some View {
		HStack(spacing: 4) {
			Spacer().frame(width: 12)
			Image(systemName: "doc")
				.font(.system(size: 11))
				.foregroundStyle(Theme.textSecondary)
			TextField("New file name", text: $state.newFileName)
				.textFieldStyle(.plain)
				.font(.system(size: 12))
				.foregroundStyle(Theme.textPrimary)
				.focused($focused)
				.onSubmit { state.commitCreateFile(project: project) }
				.onExitCommand { state.cancelCreateFile() }
				.onAppear { focused = true }
				.onChange(of: focused) { _, isFocused in
					// Focus が外れた時、入力空なら cancel (= UI 的に "捨てる")。
					// 何か入力してた場合は確定したかったかもしれないので残す。
					if !isFocused && state.newFileName.isEmpty {
						state.cancelCreateFile()
					}
				}
			Spacer()
		}
		.padding(.leading, 6)
		.padding(.vertical, 3)
		.padding(.trailing, 6)
		.background(Theme.surfaceActive)
	}
}

struct FileTreeRow: View {
	let item: FileItem
	let depth: Int
	@ObservedObject var state: FileTreeState
	let project: Project
	let rootPath: String
	let onFileSelect: (String) -> Void
	var gitFileStatus: [String: String] = [:]
	@State private var isHovering = false
	@FocusState private var renameFocused: Bool
	@FocusState private var newFileFocused: Bool

	private var isFocused: Bool {
		state.focusedPath == item.path
	}

	private var isSelected: Bool {
		state.selectedPaths.contains(item.path)
	}

	private var isLoading: Bool {
		state.loadingDirectories.contains(item.path)
	}

	private var isExpanded: Bool {
		state.expandedPaths.contains(item.path)
	}

	private var children: [FileItem] {
		state.childrenCache[item.path] ?? []
	}

	private var isRenaming: Bool {
		state.renamingPath == item.path
	}

	private var gitStatus: String? {
		// gitFileStatus keys are relative paths (files + directories)
		// item.path is absolute — match by suffix
		for (gitPath, status) in gitFileStatus {
			if item.path.hasSuffix("/" + gitPath) {
				return status
			}
		}
		return nil
	}

	private var gitStatusBadge: String? {
		guard let s = gitStatus else { return nil }
		switch s {
		case "M": return "M"
		case "A", "??": return "A"
		case "D": return "D"
		case "R": return "R"
		default: return s
		}
	}

	private var isIgnored: Bool {
		state.ignoredPaths.contains(item.path)
	}

	private var gitStatusColor: Color? {
		if isIgnored { return Theme.textTertiary }
		guard let s = gitStatus else { return nil }
		switch s {
		case "M": return Theme.yellow
		case "A", "??": return Theme.green
		case "D": return Theme.red
		default: return Theme.yellow
		}
	}

	private var rowBackground: Color {
		if isFocused && isSelected {
			return Theme.surfaceActive
		} else if isFocused {
			return Theme.surfaceActive
		} else if isSelected {
			return Theme.surfaceSelected
		} else if isHovering {
			return Theme.surfaceHover
		}
		return Color.clear
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 4) {
				if item.isDirectory {
					Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
						.font(.system(size: 8, weight: .bold))
						.foregroundStyle(Theme.textTertiary)
						.frame(width: 12)
				} else {
					Spacer()
						.frame(width: 12)
				}

				FileTypeIconView(name: item.name, isDirectory: item.isDirectory)

				if isRenaming {
					TextField("", text: $state.renamingText)
						.textFieldStyle(.plain)
						.font(.system(size: 12))
						.foregroundStyle(Theme.textPrimary)
						.focused($renameFocused)
						.onSubmit {
							state.commitRename(project: project)
						}
						.onExitCommand {
							state.cancelRename()
						}
						.onAppear {
							renameFocused = true
						}
				} else {
					Text(item.displayName)
						.font(.system(size: 12))
						.foregroundStyle(gitStatusColor ?? Theme.textPrimary)
						.lineLimit(1)
				}

				Spacer()

				if let badge = gitStatusBadge {
					Text(badge)
						.font(.system(size: 9, weight: .bold, design: .monospaced))
						.foregroundStyle(gitStatusColor ?? Theme.textTertiary)
				}
			}
			.padding(.leading, CGFloat(depth) * 14 + 6)
			.padding(.vertical, 3)
			.padding(.trailing, 6)
			.background(rowBackground)
			.contentShape(Rectangle())
			.onTapGesture {
				let now = Date()
				let modifiers = NSApp.currentEvent?.modifierFlags ?? []

				// Double-click detection (same path within 300ms, no modifiers)
				if state.lastClickedPath == item.path,
				   now.timeIntervalSince(state.lastClickTime) < 0.3,
				   !modifiers.contains(.shift), !modifiers.contains(.command) {
					state.lastClickedPath = nil
					state.startRename()
					return
				}

				state.lastClickedPath = item.path
				state.lastClickTime = now

				if modifiers.contains(.shift) {
					state.selectRange(to: item.path)
				} else if modifiers.contains(.command) {
					state.toggleSelection(item.path)
				} else {
					state.selectSingle(item.path)
					if item.isDirectory {
						state.toggle(path: item.path, project: project)
					} else {
						onFileSelect(item.path)
					}
				}
			}
			.onHover { hovering in
				isHovering = hovering
			}
			.contextMenu {
				Button("Copy Full Path") {
					copyToClipboard(absolutePath(item.path))
				}
				Button("Copy Relative Path") {
					copyToClipboard(relativePath(item.path))
				}
				if item.isDirectory {
					Divider()
					Button("New File") {
						state.startCreateFile(in: item.path)
					}
				}
				Divider()
				Button("Delete", role: .destructive) {
					state.requestDelete(paths: [item.path], project: project)
				}
			}
			.id(item.path)
			.accessibilityLabel(item.name)

			if item.isDirectory && isLoading {
				HStack {
					DirectoryLoadingLine()
						.frame(maxWidth: .infinity, minHeight: 10, maxHeight: 10)
					Spacer()
				}
				.padding(.leading, CGFloat(depth) * 14 + 28)
				.padding(.trailing, 6)
				.padding(.top, 1)
				.padding(.bottom, 4)
			}

			// New file input (shown as first child when creating in this directory)
			if item.isDirectory && state.creatingInPath == item.path {
				HStack(spacing: 4) {
					Spacer()
						.frame(width: 12)
					Image(systemName: "doc")
						.font(.system(size: 11))
						.foregroundStyle(Theme.textSecondary)
					TextField("New file name", text: $state.newFileName)
						.textFieldStyle(.plain)
						.font(.system(size: 12))
						.foregroundStyle(Theme.textPrimary)
						.focused($newFileFocused)
						.onSubmit {
							state.commitCreateFile(project: project)
						}
						.onExitCommand {
							state.cancelCreateFile()
						}
						.onAppear {
							newFileFocused = true
						}
						.onChange(of: newFileFocused) { _, isFocused in
							if !isFocused && state.newFileName.isEmpty {
								state.cancelCreateFile()
							}
						}
					Spacer()
				}
				.padding(.leading, CGFloat(depth + 1) * 14 + 6)
				.padding(.vertical, 3)
				.padding(.trailing, 6)
				.background(Theme.surfaceActive)
			}

			// Children
			if item.isDirectory, isExpanded {
				ForEach(children) { child in
					FileTreeRow(
						item: child,
						depth: depth + 1,
						state: state,
						project: project,
						rootPath: rootPath,
						onFileSelect: onFileSelect,
						gitFileStatus: gitFileStatus
					)
				}
			}
		}
	}

	private func copyToClipboard(_ s: String) {
		let pb = NSPasteboard.general
		pb.clearContents()
		pb.setString(s, forType: .string)
	}

	private func relativePath(_ absolute: String) -> String {
		var p = absolute
		let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
		if p.hasPrefix(prefix) {
			p = String(p.dropFirst(prefix.count))
		} else if p == rootPath {
			p = ""
		}
		// DevContainer の effectivePath は "." なので "./tasks/..." 形式に
		// なる。先頭の "./" を剥がしてピュアな相対パスにする。
		if p.hasPrefix("./") {
			p = String(p.dropFirst(2))
		}
		return p
	}

	/// Absolute path suitable for "Copy Full Path".
	/// - Local / SSH: `item.path` is already absolute (effectivePath は実パス)。
	/// - DevContainer: effectivePath が `.` のため `item.path = "./tasks/..."`。
	///   `RemoteRPCRegistry.cwd(for:)` (broker から `pwd` op で取得) を prefix
	///   して `/workspaces/.../tasks/...` に解決する。cwd 未取得なら剥がしただけ
	///   の相対パスを返す (broker が pwd op に未対応な旧版でも壊れない)。
	private func absolutePath(_ itemPath: String) -> String {
		if !itemPath.hasPrefix("./") {
			return itemPath
		}
		let rel = relativePath(itemPath)
		if let cwd = RemoteRPCRegistry.shared.cwd(for: project.id), !cwd.isEmpty {
			return (cwd as NSString).appendingPathComponent(rel)
		}
		return rel
	}

	private func fileIcon(_ name: String) -> String {
		let ext = (name as NSString).pathExtension.lowercased()
		switch ext {
		case "swift": return "swift"
		case "js", "ts", "jsx", "tsx": return "j.square"
		case "py": return "p.square"
		case "md": return "doc.richtext"
		case "json": return "curlybraces"
		case "html", "htm": return "chevron.left.forwardslash.chevron.right"
		case "css": return "paintbrush"
		case "sh", "bash", "zsh": return "terminal"
		default: return "doc"
		}
	}
}

private struct FileTreeLoadingLine: View {
	var body: some View {
		LoadingTrack(trackHeight: 2, widthFactor: 0.3, minimumWidth: 110)
			.frame(height: 2)
			.frame(maxWidth: .infinity, alignment: .leading)
			.allowsHitTesting(false)
	}
}

private struct DirectoryLoadingLine: View {
	var body: some View {
		LoadingTrack(trackHeight: 2, widthFactor: 0.45, minimumWidth: 18, capsuleTrack: true)
	}
}
