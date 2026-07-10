import SwiftUI

struct OpenFile: Equatable {
	let path: String
	let content: String
	let line: Int?
	let column: Int?
}

private struct FileSearchResult: Identifiable, Hashable {
	let id = UUID()
	let path: String
	let relativePath: String
	let lineNumber: Int?
	let snippet: String?
	let matchedFilename: Bool
}

struct PreviewArea: View {
	let project: Project
	@ObservedObject var layoutState: ProjectLayoutState
	@Binding var openFile: OpenFile?
	@EnvironmentObject var projectStore: ProjectStore
	@StateObject private var fileTreeState = FileTreeState()
	@State private var isDirty = false
	/// The on-disk content (updated on successful save). Used as the reference for
	/// dirty-check without re-assigning openFile (which would re-init the editor).
	@State private var savedContentReference: String = ""
	@State private var editedContent: String = ""
	// showChanges is persisted via layoutState.showChanges
	@State private var loadingPath: String?
	@State private var fileWatchTimer: Timer?
	@State private var lastKnownModTime: Date?
	/// RPC fast path: 親ディレクトリの fsnotify watch ID。watch 中だけ非 nil。
	@State private var fileWatchRPCID: String?
	/// 上記 watch の対象 dir。同じ dir に開き直した時に re-watch しないため。
	@State private var fileWatchRPCDir: String?
	/// RPC push 購読済みの client。client が再作成されたら再購読が必要なので
	/// bool ではなく client の identity で管理する (= 再接続後に push が
	/// 届かなくなる問題の対策)。
	@State private var fileWatchSubscribedClient: RemoteRPCClient?
	@State private var isFileSearchPresented = false
	@State private var fileSearchQuery = ""
	@State private var fileSearchResults: [FileSearchResult] = []
	@State private var selectedSearchIndex = 0
	@State private var isSearchingFiles = false
	@State private var searchRevision = 0
	@State private var searchWorkItem: DispatchWorkItem?
	@FocusState private var isFileSearchFocused: Bool
	@State private var isEditorFocused: Bool = false
	/// Markdown ファイルの「編集モード」フラグ (ファイル切替で reset)。
	/// false (default) = `MarkdownPreviewView` でレンダリング表示
	/// true = `CodeEditorView` (CodeMirror) で plain text 編集
	@State private var markdownEditMode = false

	private var rootPath: String {
		project.effectivePath
	}

	/// Markdown ファイル時に右下に出る Preview ⇄ Edit toggle ボタン。
	private var markdownEditToggleButton: some View {
		Button {
			markdownEditMode.toggle()
		} label: {
			HStack(spacing: 4) {
				Image(systemName: markdownEditMode ? "doc.text" : "pencil")
					.font(.system(size: 11, weight: .medium))
				Text(markdownEditMode ? "Preview" : "Edit")
					.font(.system(size: 11, weight: .medium))
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(
				RoundedRectangle(cornerRadius: 6)
					.fill(Theme.surface.opacity(0.92))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 6)
					.stroke(Theme.borderSubtle, lineWidth: 1)
			)
			.foregroundStyle(Theme.textPrimary)
		}
		.buttonStyle(.plain)
		.help(markdownEditMode ? "Switch to preview" : "Edit raw markdown")
	}

	var body: some View {
		GeometryReader { geo in
			HStack(spacing: 0) {
				let treeOnLeft = AppConfig.shared.fileTreePosition == .left

				if layoutState.showFileTree && !layoutState.showChanges && treeOnLeft {
					fileTreeSection(geo: geo, onLeft: true)
				}

				if layoutState.showChanges {
					ChangesView(project: project, layoutState: layoutState, onOpenFile: { path in
						layoutState.showChanges = false
						loadFile(at: path)
					}, onDismiss: {
						layoutState.showChanges = false
					})
				} else {
					editorContent
				}

				if layoutState.showFileTree && !layoutState.showChanges && !treeOnLeft {
					fileTreeSection(geo: geo, onLeft: false)
				}
			}
			.overlay(alignment: .top) {
				if isFileSearchPresented {
					fileSearchOverlay
						.padding(.top, 10)
						transition(.move(edge: .top).combined(with: .opacity))
				}
			}
		}
		.onChange(of: openFile) {
			isDirty = false
			editedContent = openFile?.content ?? ""
			savedContentReference = openFile?.content ?? ""
			startFileWatch()
			// Persist only when we actually have a file open. A nil transition
			// frequently comes from a project switch clearing the shared
			// `openFile` state — writing nil here would wipe the saved
			// `lastOpenedFile` for this project and break restore on re-entry.
			if let path = openFile?.path {
				layoutState.lastOpenedFile = path
			}
			guard let file = openFile else { return }
			NotificationCenter.default.post(
				name: .belveRevealFileInTree,
				object: nil,
				userInfo: ["projectId": project.id, "path": file.path]
			)
		}
		.onDisappear {
			stopFileWatch()
		}
		.onAppear {
			// Restore previously open file. Remote providers may not be
			// ready on first call; loadFile retries internally for those.
			if openFile == nil, let savedPath = layoutState.lastOpenedFile {
				NSLog("[Belve][restore] project=%@ tries to restore file=%@", project.name, savedPath)
				loadFile(at: savedPath)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveFileSave)) { _ in
			saveCurrentFile()
			projectStore.refreshGitStatus()
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveShowChanges)) { notif in
			if let projectId = notif.userInfo?["projectId"] as? UUID {
				if projectId != project.id { return }
			} else if projectStore.selectedProject?.id != project.id {
				// projectId 未指定 (= Cmd+Shift+G 等) は currently selected project だけ反応。
				// これを入れないと全 PreviewArea が toggle して他 view にも波及する。
				return
			}
			layoutState.showChanges.toggle()
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveFileDeleted)) { notif in
			if let deletedPaths = notif.object as? [String],
			   let current = openFile?.path,
			   deletedPaths.contains(current) {
				openFile = nil
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveOpenFileFromTerminal)) { notif in
			guard let projectId = notif.userInfo?["projectId"] as? UUID,
				  projectId == project.id,
				  let path = notif.userInfo?["path"] as? String else { return }
			loadFile(
				at: path,
				line: notif.userInfo?["line"] as? Int,
				column: notif.userInfo?["column"] as? Int
			)
		}
		.onReceive(NotificationCenter.default.publisher(for: .belvePresentFileSearch)) { notif in
			if let projectId = notif.userInfo?["projectId"] as? UUID, projectId != project.id {
				return
			}
			presentFileSearch()
		}
		.onChange(of: fileSearchQuery) {
			selectedSearchIndex = 0
			scheduleFileSearch()
		}
	}

	@ViewBuilder
	private func fileTreeSection(geo: GeometryProxy, onLeft: Bool) -> some View {
		Group {
			if !onLeft {
				SplitDivider(
					position: Binding(
						get: { layoutState.fileTreeWidth },
						set: { layoutState.fileTreeWidth = $0 }
					),
					minLeft: 220,
					minRight: 120,
					availableWidth: geo.size.width
				)
				.frame(width: DividerMetrics.absoluteHitWidth)
			}

			FileTreeView(
				project: project,
				rootPath: rootPath,
				onFileSelect: { path in
					loadFile(at: path)
				},
				state: fileTreeState,
				gitFileStatus: projectStore.gitFileStatus,
				currentFilePath: openFile?.path ?? layoutState.lastOpenedFile
			)
			.frame(width: layoutState.fileTreeWidth)

			if onLeft {
				SplitDivider(
					position: Binding(
						get: { layoutState.fileTreeWidth },
						set: { layoutState.fileTreeWidth = $0 }
					),
					minLeft: 120,
					minRight: 220,
					availableWidth: geo.size.width
				)
				.frame(width: DividerMetrics.absoluteHitWidth)
			}
		}
		.transition(.asymmetric(
			insertion: .modifier(
				active: PreviewSidebarVisibilityModifier(xOffset: onLeft ? -10 : 10, opacity: 0),
				identity: PreviewSidebarVisibilityModifier(xOffset: 0, opacity: 1)
			),
			removal: .modifier(
				active: PreviewSidebarVisibilityModifier(xOffset: onLeft ? -8 : 8, opacity: 0),
				identity: PreviewSidebarVisibilityModifier(xOffset: 0, opacity: 1)
			)
		))
	}

	private var editorContent: some View {
		editorContentBody
			.overlay(FocusBorderOverlay(isActive: isEditorFocused))
			.onReceive(NotificationCenter.default.publisher(for: .belveEditorWebViewDidFocus)) { _ in
				withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)) {
					isEditorFocused = true
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: .belveTerminalFocused)) { _ in
				withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)) {
					isEditorFocused = false
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: .belveFileTreeFocused)) { _ in
				withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)) {
					isEditorFocused = false
				}
			}
	}

	@ViewBuilder
	private var editorContentBody: some View {
		if let file = openFile {
			VStack(spacing: 0) {
				HStack(spacing: 6) {
					Image(systemName: "doc.text")
						.font(.system(size: 10))
						.foregroundStyle(Theme.textSecondary)
					Text((file.path as NSString).lastPathComponent)
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(Theme.textPrimary)
						.lineLimit(1)
					if isDirty {
						Circle()
							.fill(Theme.textSecondary)
							.frame(width: 6, height: 6)
						// Revert: sits next to the dirty dot so the visual
						// association ("this dot says edited → this icon undoes
						// those edits") is immediate. Uses a U-turn arrow,
						// which reads as "go back" across most UIs.
						Button {
							reloadFromDisk()
						} label: {
							Image(systemName: "arrow.uturn.backward")
								.font(.system(size: 10, weight: .medium))
								.foregroundStyle(Theme.textSecondary)
						}
						.buttonStyle(.plain)
						.tooltip("Revert · discard edits and reload from disk")
					}
					Spacer()
					Button {
						openFile = nil
						isDirty = false
					} label: {
						Image(systemName: "xmark")
							.font(.system(size: 9, weight: .medium))
							.foregroundStyle(Theme.textTertiary)
					}
					.buttonStyle(.plain)
				}
				.padding(.horizontal, 10)
				.padding(.vertical, 5)
				.background(Theme.bg)

				Theme.borderSubtle
					.frame(height: 1)

				Group {
					switch FileType.detect(path: file.path) {
					case .image, .video, .pdf:
						MediaPreviewView(path: file.path, provider: project.provider)
					case .markdown:
						// Default は読みやすい preview レンダリング。Edit toggle で
						// CodeMirror に切替えて plain text 編集できる。
						ZStack(alignment: .bottomTrailing) {
							if markdownEditMode {
								CodeEditorView(
									projectId: project.id,
									project: project,
									filename: file.path,
									content: file.content,
									line: file.line,
									column: file.column,
									onDefinitionRequest: handleDefinitionRequest,
									onDefinitionHoverRequest: handleDefinitionHoverRequest,
										onHoverInfoRequest: handleHoverInfoRequest
								) { newContent in
									editedContent = newContent
									isDirty = newContent != savedContentReference
								}
							} else {
								MarkdownPreviewView(content: file.content, filePath: file.path, provider: project.provider)
							}
							markdownEditToggleButton
								.padding(12)
						}
					case .code, .unknown:
						CodeEditorView(
							projectId: project.id,
							project: project,
							filename: file.path,
							content: file.content,
							line: file.line,
							column: file.column,
							onDefinitionRequest: handleDefinitionRequest,
							onDefinitionHoverRequest: handleDefinitionHoverRequest,
							onHoverInfoRequest: handleHoverInfoRequest
						) { newContent in
							editedContent = newContent
							isDirty = newContent != savedContentReference
						}
					}
				}
				.id(file.path)
				.onChange(of: file.path) { _, _ in
					// ファイル切替時は Edit モードを reset (= 新ファイルは Preview で開く)
					markdownEditMode = false
				}
			}
			.overlay(alignment: .topLeading) {
				if let loadingPath {
					LoadingTopLine(filename: (loadingPath as NSString).lastPathComponent)
				}
			}
		} else {
			VStack(spacing: 8) {
				Image(systemName: "doc.text.magnifyingglass")
					.font(.system(size: 28, weight: .thin))
					.foregroundStyle(Theme.textTertiary)
				Text("Select a file")
					.font(Theme.fontBody)
					.foregroundStyle(Theme.textTertiary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(Theme.surface)
			.overlay(alignment: .topLeading) {
				if let loadingPath {
					LoadingTopLine(filename: (loadingPath as NSString).lastPathComponent)
				}
			}
		}
	}

	private var fileSearchOverlay: some View {
		VStack(spacing: 0) {
			VStack(spacing: 0) {
				HStack(spacing: 10) {
					Image(systemName: "magnifyingglass")
						.font(.system(size: 12, weight: .semibold))
						.foregroundStyle(Theme.textTertiary)

					TextField("Search files and code...", text: $fileSearchQuery)
						.textFieldStyle(.plain)
						.font(.system(size: 14))
						.foregroundStyle(Theme.textPrimary)
						.focused($isFileSearchFocused)
						.onSubmit {
							openSelectedSearchResult()
						}

					if !fileSearchQuery.isEmpty {
						Text("\(fileSearchResults.count)")
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(Theme.textSecondary)
					}
				}
				.padding(.horizontal, 14)
				.padding(.vertical, 12)

				Theme.borderSubtle.frame(height: 1)
			}

			Group {
				if fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					searchEmptyState(label: "Type to search by filename or file contents")
				} else if isSearchingFiles && fileSearchResults.isEmpty {
					searchEmptyState(label: "Searching…")
				} else if fileSearchResults.isEmpty {
					searchEmptyState(label: "No matches")
				} else {
					ScrollView {
						VStack(spacing: 0) {
							ForEach(Array(fileSearchResults.enumerated()), id: \.element.id) { index, result in
								FileSearchRow(result: result, isSelected: index == selectedSearchIndex)
									.onTapGesture {
										selectedSearchIndex = index
										open(result)
									}
							}
						}
					}
					.frame(maxHeight: 340)
				}
			}
		}
		.frame(width: 560)
		.background(Theme.surface)
		.cornerRadius(Theme.radiusLg)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusLg)
				.stroke(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.34), radius: 18, y: 8)
		.onKeyPress(.upArrow) {
			guard !fileSearchResults.isEmpty else { return .handled }
			selectedSearchIndex = max(0, selectedSearchIndex - 1)
			return .handled
		}
		.onKeyPress(.downArrow) {
			guard !fileSearchResults.isEmpty else { return .handled }
			selectedSearchIndex = min(fileSearchResults.count - 1, selectedSearchIndex + 1)
			return .handled
		}
		.onKeyPress(.return) {
			openSelectedSearchResult()
			return .handled
		}
		.onKeyPress(.escape) {
			closeFileSearch()
			return .handled
		}
		.onAppear {
			isFileSearchFocused = true
		}
	}

	private func searchEmptyState(label: String) -> some View {
		HStack {
			Text(label)
				.font(.system(size: 12))
				.foregroundStyle(Theme.textSecondary)
			Spacer()
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 14)
	}

	private func presentFileSearch() {
		withAnimation(.easeOut(duration: 0.12)) {
			isFileSearchPresented = true
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
			isFileSearchFocused = true
		}
	}

	private func closeFileSearch() {
		withAnimation(.easeOut(duration: 0.1)) {
			isFileSearchPresented = false
		}
		searchWorkItem?.cancel()
		isSearchingFiles = false
		fileSearchQuery = ""
		fileSearchResults = []
		selectedSearchIndex = 0
	}

	private func openSelectedSearchResult() {
		guard selectedSearchIndex >= 0, selectedSearchIndex < fileSearchResults.count else { return }
		open(fileSearchResults[selectedSearchIndex])
	}

	private func open(_ result: FileSearchResult) {
		closeFileSearch()
		loadFile(at: result.path, line: result.lineNumber)
	}

	private func scheduleFileSearch() {
		searchWorkItem?.cancel()
		let query = fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else {
			isSearchingFiles = false
			fileSearchResults = []
			return
		}

		let workItem = DispatchWorkItem { [searchRevision] in
			_ = searchRevision
			runFileSearch()
		}
		searchWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
	}

	private func runFileSearch() {
		let query = fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		searchRevision += 1
		let revision = searchRevision

		guard !query.isEmpty else {
			isSearchingFiles = false
			fileSearchResults = []
			return
		}

		isSearchingFiles = true
		DispatchQueue.global(qos: .userInitiated).async {
			let filenameResults = searchFileNames(query: query, limit: 40)
			// ファイル名で当たったものは中身検索から除外して重複を避ける。
			let excluded = Set(filenameResults.map(\.path))
			let contentResults = searchFileContents(query: query, limit: 40, excluding: excluded)
			let combined = filenameResults + contentResults
			DispatchQueue.main.async {
				guard revision == searchRevision else { return }
				fileSearchResults = combined
				isSearchingFiles = false
			}
		}
	}

	private func searchFileContents(query: String, limit: Int, excluding: Set<String>) -> [FileSearchResult] {
		project.provider.searchFileContents(rootPath: rootPath, query: query, limit: limit, excludingPaths: excluding).map { match in
			FileSearchResult(
				path: match.path,
				relativePath: relativeDisplayPath(for: match.path),
				lineNumber: match.lineNumber,
				snippet: match.snippet,
				matchedFilename: match.matchedFilename
			)
		}
	}

	private func searchFileNames(query: String, limit: Int) -> [FileSearchResult] {
		project.provider.searchFileNames(rootPath: rootPath, query: query, limit: limit).map { match in
			FileSearchResult(
				path: match.path,
				relativePath: relativeDisplayPath(for: match.path),
				lineNumber: match.lineNumber,
				snippet: match.snippet,
				matchedFilename: match.matchedFilename
			)
		}
	}

	private func relativeDisplayPath(for path: String) -> String {
		var relative = path
		if rootPath != ".", path.hasPrefix(rootPath) {
			relative = String(path.dropFirst(rootPath.count))
			if relative.hasPrefix("/") {
				relative.removeFirst()
			}
		}
		if relative.hasPrefix("./") {
			relative = String(relative.dropFirst(2))
		}
		return relative.isEmpty ? (path as NSString).lastPathComponent : relative
	}

	private func loadFile(at path: String, line: Int? = nil, column: Int? = nil, retriesRemaining: Int = 5) {
		NSLog("[Belve] loadFile: \(path) (retries left=\(retriesRemaining))")
		// Push current position to navigation history before switching files
		let navManager = NavigationHistoryManager.shared
		if !navManager.isNavigating, let current = openFile, current.path != path {
			let viewId = ProjectViewStore.shared.activeView(for: project.id).id
			navManager.push(viewId: viewId, entry: NavigationEntry(
				path: current.path, line: current.line ?? 1, column: current.column ?? 1
			))
			navManager.push(viewId: viewId, entry: NavigationEntry(
				path: path, line: line ?? 1, column: column ?? 1
			))
		}
		let fileType = FileType.detect(path: path)

		if fileType == .image || fileType == .pdf {
			DispatchQueue.main.async {
				loadingPath = nil
				postFileLoadingState(path: path, isLoading: false)
				openFile = OpenFile(path: path, content: "", line: line, column: column)
			}
			return
		}

		loadingPath = path
		postFileLoadingState(path: path, isLoading: true)
		let provider = project.provider
		DispatchQueue.global().async {
			if let content = provider.readFile(path) {
				NSLog("[Belve] File loaded: \(path), \(content.count) chars")
				DispatchQueue.main.async {
					loadingPath = nil
					postFileLoadingState(path: path, isLoading: false)
					openFile = OpenFile(path: path, content: content, line: line, column: column)
				}
			} else if retriesRemaining > 0 && project.isRemote {
				// Remote provider often fails on the first read after app
				// start because the SSH ControlMaster is still being
				// established. Retry with exponential-ish backoff so file
				// restoration eventually succeeds without spamming.
				let delay = Double(6 - retriesRemaining) * 0.6 + 0.4
				NSLog("[Belve] Remote read failed, retrying in %.1fs: %@", delay, path)
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
					guard openFile == nil else { return }
					loadFile(at: path, line: line, column: column, retriesRemaining: retriesRemaining - 1)
				}
			} else {
				NSLog("[Belve] Failed to read file: \(path)")
				DispatchQueue.main.async {
					if loadingPath == path {
						loadingPath = nil
						postFileLoadingState(path: path, isLoading: false)
					}
				}
			}
		}
	}

	private func postFileLoadingState(path: String, isLoading: Bool) {
		NotificationCenter.default.post(
			name: .belveFileLoadingState,
			object: nil,
			userInfo: [
				"projectId": project.id,
				"path": path,
				"isLoading": isLoading
			]
		)
	}

	/// Drop the unsaved in-editor edits and re-read the file from disk. Asks
	/// for confirmation first so this isn't catastrophic if mis-clicked.
	private func reloadFromDisk() {
		guard let file = openFile, isDirty else { return }
		let alert = NSAlert()
		alert.messageText = "Discard changes and reload?"
		alert.informativeText = "Unsaved edits to \((file.path as NSString).lastPathComponent) will be replaced with the current contents of the file on disk."
		alert.alertStyle = .warning
		alert.addButton(withTitle: "Discard & Reload")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }

		let path = file.path
		let line = file.line
		let column = file.column
		// Mark clean first so the loadFile path doesn't race with the
		// external-change watcher (which skips reload while `isDirty`).
		isDirty = false
		openFile = nil
		loadFile(at: path, line: line, column: column)
	}

	func saveCurrentFile() {
		guard let file = openFile, isDirty else { return }
		let provider = project.provider
		let contentToSave = editedContent
		DispatchQueue.global().async {
			let success = provider.writeFile(file.path, content: contentToSave)
			DispatchQueue.main.async {
				if success {
					// Don't re-assign openFile — that triggers updateNSView in the editor
					// and re-initializes CodeMirror, losing focus + caret. Just mark clean.
					isDirty = false
					// Update the "reference" content so the dirty check works next edit.
					savedContentReference = contentToSave
				}
			}
		}
	}

	private func handleDefinitionRequest(_ request: EditorDefinitionRequest) {
		let proj = project
		Task { @MainActor in
			// LSP first
			if let loc = await LSPManager.shared.definition(
				file: request.filename, line: request.line, column: request.column, project: proj
			) {
				let path = loc.uri.hasPrefix("file://") ? String(loc.uri.dropFirst(7)) : loc.uri
				loadFile(at: path, line: loc.range.start.line + 1, column: loc.range.start.character + 1)
				return
			}
			// Grep fallback
			let provider = proj.provider
			let root = rootPath
			DispatchQueue.global(qos: .userInitiated).async {
				guard let match = provider.resolveDefinition(
					rootPath: root, filePath: request.filename,
					symbol: request.symbol, language: request.language,
					line: request.line, column: request.column
				) else { return }
				DispatchQueue.main.async { [self] in
					loadFile(at: match.path, line: match.lineNumber, column: match.column)
				}
			}
		}
	}

	private func handleHoverInfoRequest(_ request: EditorDefinitionRequest, _ requestId: Int, _ completion: @escaping (String?) -> Void) {
		let proj = project
		NSLog("[Belve][hover] request file=%@ line=%d col=%d symbol=%@", request.filename, request.line, request.column, request.symbol)
		Task { @MainActor in
			if let markdown = await LSPManager.shared.hover(
				file: request.filename, line: request.line, column: request.column, project: proj
			) {
				NSLog("[Belve][hover] got response: %d chars", markdown.count)
				let html = markdownToHoverHTML(markdown)
				completion(html)
			} else {
				NSLog("[Belve][hover] no result")
				completion(nil)
			}
		}
	}

	private func grepBasedHover(_ request: EditorDefinitionRequest, _ completion: @escaping (String?) -> Void) {
		let provider = project.provider
		let root = rootPath
		DispatchQueue.global(qos: .userInitiated).async {
			guard let match = provider.resolveDefinition(
				rootPath: root, filePath: request.filename,
				symbol: request.symbol, language: request.language,
				line: request.line, column: request.column
			), let content = provider.readFile(match.path) else {
				completion(nil)
				return
			}
			let lines = content.components(separatedBy: "\n")
			let defIdx = (match.lineNumber ?? 1) - 1
			guard defIdx >= 0 && defIdx < lines.count else { completion(nil); return }

			let signature = lines[defIdx].trimmingCharacters(in: .whitespaces)
			var docLines: [String] = []
			var i = defIdx - 1
			while i >= 0 {
				let t = lines[i].trimmingCharacters(in: .whitespaces)
				if t.hasPrefix("#") || t.hasPrefix("//") || t.hasPrefix("///") ||
				   t.hasPrefix("*") || t.hasPrefix("/*") ||
				   t.hasPrefix("\"\"\"") || t.hasPrefix("'''") {
					docLines.insert(t, at: 0)
					i -= 1
				} else { break }
			}
			if defIdx + 1 < lines.count {
				let next = lines[defIdx + 1].trimmingCharacters(in: .whitespaces)
				if next.hasPrefix("\"\"\"") || next.hasPrefix("'''") {
					var j = defIdx + 1
					while j < lines.count {
						let t = lines[j].trimmingCharacters(in: .whitespaces)
						docLines.append(t)
						if j > defIdx + 1 && (t.hasSuffix("\"\"\"") || t.hasSuffix("'''")) { break }
						j += 1
					}
				}
			}

			func esc(_ s: String) -> String {
				s.replacingOccurrences(of: "&", with: "&amp;")
				 .replacingOccurrences(of: "<", with: "&lt;")
				 .replacingOccurrences(of: ">", with: "&gt;")
			}
			var html = "<div class='hover-signature'>\(esc(signature))</div>"
			if !docLines.isEmpty {
				html += "<div class='hover-doc'>\(docLines.map { esc($0) }.joined(separator: "<br>"))</div>"
			}
			completion(html)
		}
	}

	private func markdownToHoverHTML(_ md: String) -> String {
		func esc(_ s: String) -> String {
			s.replacingOccurrences(of: "&", with: "&amp;")
			 .replacingOccurrences(of: "<", with: "&lt;")
			 .replacingOccurrences(of: ">", with: "&gt;")
		}
		var html = ""
		var inCode = false
		for line in md.components(separatedBy: "\n") {
			if line.hasPrefix("```") {
				if inCode {
					html += "</pre>"
					inCode = false
				} else {
					html += "<pre>"
					inCode = true
				}
			} else if inCode {
				html += esc(line) + "\n"
			} else if line.hasPrefix("`") && line.hasSuffix("`") {
				html += "<div class='hover-signature'>\(esc(String(line.dropFirst().dropLast())))</div>"
			} else if !line.isEmpty {
				html += "<div class='hover-doc'>\(esc(line))</div>"
			}
		}
		if inCode { html += "</pre>" }
		return html
	}

	// MARK: - File Watch (auto-reload on external changes)

	private func startFileWatch() {
		stopFileWatch()
		guard let file = openFile else { return }
		logFileWatch("startFileWatch path=\(file.path) remote=\(project.isRemote) subscribed=\(fileWatchSubscribedClient != nil)")
		NSLog("[Belve][filewatch] start path=%@ remote=%d", file.path, project.isRemote ? 1 : 0)
		if project.isRemote {
			if let client = RemoteRPCRegistry.shared.client(for: project.id) {
				logFileWatch("startFileWatch: got RPC client, starting watch")
				startFileWatchRPC(file: file, client: client)
				return
			}
			logFileWatch("startFileWatch: no RPC client, will retry")
			let projectId = project.id
			DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
				guard let file = openFile else { return }
				if let client = RemoteRPCRegistry.shared.client(for: projectId) {
					logFileWatch("startFileWatch: retry succeeded")
					startFileWatchRPC(file: file, client: client)
				} else {
					logFileWatch("startFileWatch: retry failed, no RPC client")
				}
			}
			return
		}
		// Local: macOS FSEvents 化は別仕事、当面 2 秒 polling のまま。
		startFileWatchPolling(file: file)
	}

	private func startFileWatchRPC(file: OpenFile, client: RemoteRPCClient) {
		// Push 購読は client ごとに 1 回。client が再作成されたら (= 再接続後)
		// 新しい client に再購読 + dir watch を強制再登録する。
		// closure 側で「現在の openFile.path と一致する event のみ」を
		// フィルタするので、ファイル切替時は re-subscribe 不要。
		if fileWatchSubscribedClient !== client {
			fileWatchSubscribedClient = client
			fileWatchRPCDir = nil
			fileWatchRPCID = nil
			client.subscribePush { type, msg in
				if type == "fsevent" {
					let line = "\(Date()) push type=\(type) kind=\(msg["kind"] ?? "?") path=\(msg["path"] ?? "?")\n"
					if let d = line.data(using: .utf8) {
						let u = URL(fileURLWithPath: "/tmp/belve-filewatch.log")
						if let fh = try? FileHandle(forWritingTo: u) { fh.seekToEndOfFile(); fh.write(d); fh.closeFile() }
						else { try? d.write(to: u) }
					}
				}
				guard type == "fsevent",
				      let evPath = msg["path"] as? String,
				      let kind = msg["kind"] as? String,
				      kind == "modify" || kind == "create" || kind == "rename"
				else { return }
				DispatchQueue.main.async {
					handleExternalFileChange(at: evPath)
				}
			}
		}

		let rawDir = (file.path as NSString).deletingLastPathComponent
		// 相対パス (DevContainer の effectivePath="." 由来) を broker の cwd で
		// 絶対パスに解決。broker 側の fsnotify は CWD 非依存で動くため、
		// 相対パスのまま送ると wrong dir を watch する。
		let dir: String
		if rawDir.hasPrefix("/") || rawDir.hasPrefix("~") {
			// 絶対 or チルダ — broker 側の expandHome が解決する
			dir = rawDir
		} else if let cwd = RemoteRPCRegistry.shared.cwd(for: project.id) {
			let joined = rawDir == "." ? cwd : (cwd as NSString).appendingPathComponent(rawDir)
			dir = (joined as NSString).standardizingPath
		} else {
			dir = rawDir
		}
		// 同じ dir なら watch 流用 — re-watch コストを節約。
		if fileWatchRPCDir != dir {
			// 古い watch を解除
			if let oldID = fileWatchRPCID {
				Task { _ = try? await client.send(op: "unwatch", params: ["watchId": oldID]) }
			}
			fileWatchRPCID = nil
			fileWatchRPCDir = dir
			// 新規 watch 登録
			Task {
				do {
					let res = try await client.send(op: "watch", params: ["path": dir])
					if let id = res.result?["watchId"] as? String {
						logFileWatch("watch registered dir=\(dir) watchId=\(id)")
						await MainActor.run { fileWatchRPCID = id }
					} else {
						logFileWatch("watch returned no watchId dir=\(dir)")
					}
				} catch {
					logFileWatch("watch failed dir=\(dir): \(error.localizedDescription)")
				}
			}
		}
	}

	/// openFile.path (相対 or 絶対) と fsevent path (絶対) を比較。
	/// DevContainer は openFile.path が "./foo" で fsevent が "/workspace/foo" のように
	/// 不一致になるので、cwd で解決して比較する。
	private func resolveFilePath(_ path: String) -> String {
		if path.hasPrefix("/") { return path }
		if let cwd = RemoteRPCRegistry.shared.cwd(for: project.id) {
			let joined = path == "." ? cwd : (cwd as NSString).appendingPathComponent(path)
			return (joined as NSString).standardizingPath
		}
		return path
	}

	/// fsevent path (絶対) と openFile.path (~/... or 相対 or 絶対) を比較。
	/// SSH プロジェクトの ~ パスは絶対パスの末尾と一致するかで判定する。
	private func pathsMatch(_ evPath: String, _ filePath: String) -> Bool {
		if evPath == filePath { return true }
		let resolved = resolveFilePath(filePath)
		if evPath == resolved { return true }
		// ~/src/foo → evPath が /home/user/src/foo の場合、末尾一致で判定
		if filePath.hasPrefix("~/") {
			let suffix = String(filePath.dropFirst(1)) // "/src/foo"
			return evPath.hasSuffix(suffix)
		}
		return false
	}

	private func logFileWatch(_ msg: String) {
		let line = "\(Date()) \(msg)\n"
		if let d = line.data(using: .utf8) {
			let u = URL(fileURLWithPath: "/tmp/belve-filewatch.log")
			if let fh = try? FileHandle(forWritingTo: u) { fh.seekToEndOfFile(); fh.write(d); fh.closeFile() }
			else { try? d.write(to: u) }
		}
	}

	private func handleExternalFileChange(at evPath: String) {
		guard let current = openFile else {
			logFileWatch("handleChange: no openFile")
			return
		}
		let matched = pathsMatch(evPath, current.path)
		logFileWatch("handleChange: evPath=\(evPath) current=\(current.path) matched=\(matched) isDirty=\(isDirty)")
		guard matched, !isDirty else { return }
		// readFile と openFile 更新は元の相対パス (= current.path) を使う。
		// evPath は fsevent 由来の絶対パスなので provider.readFile に渡すと
		// 相対パスベースの provider (DevContainer 等) で読めない。
		let originalPath = current.path
		let oldLen = current.content.count
		let provider = project.provider
		DispatchQueue.global(qos: .utility).async {
			guard let newContent = provider.readFile(originalPath) else {
				logFileWatch("handleChange: readFile nil path=\(originalPath)")
				return
			}
			DispatchQueue.main.async {
				guard let currentFile = openFile, currentFile.path == originalPath else {
					logFileWatch("handleChange: openFile changed under us path=\(originalPath)")
					return
				}
				guard !isDirty else {
					logFileWatch("handleChange: dropped, isDirty path=\(originalPath)")
					return
				}
				if newContent != currentFile.content {
					logFileWatch("handleChange: UPDATED path=\(originalPath) len \(oldLen)→\(newContent.count)")
					openFile = OpenFile(
						path: originalPath,
						content: newContent,
						line: currentFile.line,
						column: currentFile.column
					)
				} else {
					logFileWatch("handleChange: content identical (readFile stale?) path=\(originalPath) len=\(newContent.count)")
				}
			}
		}
	}

	private func startFileWatchPolling(file: OpenFile) {
		lastKnownModTime = project.provider.modificationDate(file.path)
		let path = file.path
		fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [self] _ in
			guard let current = openFile, current.path == path, !isDirty else { return }
			let provider = project.provider
			DispatchQueue.global(qos: .utility).async {
				guard let newModTime = provider.modificationDate(path) else { return }
				DispatchQueue.main.async {
					guard let lastMod = lastKnownModTime, newModTime > lastMod else { return }
					guard let currentFile = openFile, currentFile.path == path, !isDirty else { return }
					lastKnownModTime = newModTime
					if let newContent = provider.readFile(path) {
						if newContent != currentFile.content {
							openFile = OpenFile(
								path: path,
								content: newContent,
								line: currentFile.line,
								column: currentFile.column
							)
						}
					}
				}
			}
		}
	}

	private func stopFileWatch() {
		fileWatchTimer?.invalidate()
		fileWatchTimer = nil
		lastKnownModTime = nil
		// RPC watch は次回 startFileWatchRPC で dir 比較してから cleanup する
		// (= ディレクトリが同じなら流用、違うなら unwatch)。明示的な
		// 「全停止」が必要なら fileWatchRPCID を unwatch して nil 化する。
		if let id = fileWatchRPCID,
		   let client = RemoteRPCRegistry.shared.client(for: project.id) {
			Task { _ = try? await client.send(op: "unwatch", params: ["watchId": id]) }
		}
		fileWatchRPCID = nil
		fileWatchRPCDir = nil
	}

	private func handleDefinitionHoverRequest(_ request: EditorDefinitionRequest, completion: @escaping (Bool) -> Void) {
		let provider = project.provider
		DispatchQueue.global(qos: .userInitiated).async {
			let canJump = provider.resolveDefinition(
				rootPath: rootPath,
				filePath: request.filename,
				symbol: request.symbol,
				language: request.language,
				line: request.line,
				column: request.column
			) != nil
			completion(canJump)
		}
	}
}

private struct FileSearchRow: View {
	let result: FileSearchResult
	let isSelected: Bool
	@State private var isHovering = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 8) {
				Image(systemName: result.matchedFilename ? "doc.text" : "text.alignleft")
					.font(.system(size: 11))
					.foregroundStyle(Theme.textSecondary)
					.frame(width: 14)

				Text((result.path as NSString).lastPathComponent)
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(Theme.textPrimary)
					.lineLimit(1)

				Spacer()

				if let lineNumber = result.lineNumber {
					Text("L\(lineNumber)")
						.font(.system(size: 10, weight: .semibold))
						.foregroundStyle(Theme.textSecondary)
				}
			}

			Text(result.relativePath)
				.font(.system(size: 11))
				.foregroundStyle(Theme.textSecondary)
				.lineLimit(1)

			if let snippet = result.snippet, !snippet.isEmpty {
				Text(snippet)
					.font(.system(size: 11))
					.foregroundStyle(Theme.textPrimary.opacity(0.88))
					.lineLimit(2)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 9)
		.background(isSelected ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
		.onHover { isHovering = $0 }
	}
}

private struct PreviewSidebarVisibilityModifier: ViewModifier {
	let xOffset: CGFloat
	let opacity: Double

	func body(content: Content) -> some View {
		content
			.opacity(opacity)
			.offset(x: xOffset)
	}
}

private struct LoadingTopLine: View {
	let filename: String

	var body: some View {
		VStack(spacing: 0) {
			LoadingTrack(trackHeight: 2, widthFactor: 0.22, minimumWidth: 120)
				.frame(height: 2)

			HStack(spacing: 6) {
				Spacer()
				Text("Loading")
					.foregroundStyle(Theme.textSecondary)
				Text(filename)
					.foregroundStyle(Theme.textPrimary)
					.lineLimit(1)
			}
			.font(.system(size: 11, weight: .medium))
			.padding(.horizontal, 10)
			.padding(.top, 6)
		}
	}
}
