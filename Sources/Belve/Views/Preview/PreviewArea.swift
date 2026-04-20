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
	@State private var loadingPath: String?
	@State private var fileWatchTimer: Timer?
	@State private var lastKnownModTime: Date?
	@State private var isFileSearchPresented = false
	@State private var fileSearchQuery = ""
	@State private var fileSearchResults: [FileSearchResult] = []
	@State private var selectedSearchIndex = 0
	@State private var isSearchingFiles = false
	@State private var searchRevision = 0
	@State private var searchWorkItem: DispatchWorkItem?
	@FocusState private var isFileSearchFocused: Bool
	@State private var isEditorFocused: Bool = false

	private var rootPath: String {
		project.effectivePath
	}

	var body: some View {
		GeometryReader { geo in
			HStack(spacing: 0) {
				if layoutState.showFileTree {
					Group {
						FileTreeView(
							project: project,
							rootPath: rootPath,
							onFileSelect: { path in
								loadFile(at: path)
							},
							state: fileTreeState,
							gitFileStatus: projectStore.gitFileStatus
						)
						.frame(width: layoutState.fileTreeWidth)

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
					.transition(.asymmetric(
						insertion: .modifier(
							active: PreviewSidebarVisibilityModifier(xOffset: -10, opacity: 0),
							identity: PreviewSidebarVisibilityModifier(xOffset: 0, opacity: 1)
						),
						removal: .modifier(
							active: PreviewSidebarVisibilityModifier(xOffset: -8, opacity: 0),
							identity: PreviewSidebarVisibilityModifier(xOffset: 0, opacity: 1)
						)
					))
				}

				editorContent
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
		.onReceive(NotificationCenter.default.publisher(for: .belveFileSave)) { _ in
			saveCurrentFile()
			projectStore.refreshGitStatus()
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
					case .markdown:
						MarkdownEditorView(projectId: project.id, content: file.content) { newContent in
							editedContent = newContent
							isDirty = newContent != savedContentReference
						}
					case .image, .video, .pdf:
						MediaPreviewView(path: file.path, provider: project.provider)
					case .code, .unknown:
						CodeEditorView(
							projectId: project.id,
							project: project,
							filename: file.path,
							content: file.content,
							line: file.line,
							column: file.column,
							onDefinitionRequest: handleDefinitionRequest,
							onDefinitionHoverRequest: handleDefinitionHoverRequest
						) { newContent in
							editedContent = newContent
							isDirty = newContent != savedContentReference
						}
					}
				}
				.id(file.path)
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
			DispatchQueue.main.async {
				guard revision == searchRevision else { return }
				fileSearchResults = filenameResults
				isSearchingFiles = false
			}
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

	private func loadFile(at path: String, line: Int? = nil, column: Int? = nil) {
		NSLog("[Belve] loadFile: \(path)")
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
		let provider = project.provider
		DispatchQueue.global(qos: .userInitiated).async {
			guard let match = provider.resolveDefinition(
				rootPath: rootPath,
				filePath: request.filename,
				symbol: request.symbol,
				language: request.language,
				line: request.line,
				column: request.column
			) else { return }

			DispatchQueue.main.async {
				loadFile(at: match.path, line: match.lineNumber, column: match.column)
			}
		}
	}

	// MARK: - File Watch (auto-reload on external changes)

	private func startFileWatch() {
		stopFileWatch()
		guard let file = openFile else { return }
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
					// File changed externally — reload
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
