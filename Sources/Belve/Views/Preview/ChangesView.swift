import SwiftUI
import WebKit

struct DiffFilter {
	var staged: Bool = true
	var unstaged: Bool = true
	var committed: Bool = false
}

/// File tree の node。directory なら children あり。file なら ChangedFile を持つ。
fileprivate struct TreeNode {
	let name: String
	let fullPath: String
	let isDirectory: Bool
	let file: ChangedFile?
	var children: [TreeNode] = []
}

/// 再帰描画する tree row。直接 ViewBuilder で recursive にすると opaque type が
/// 自己参照で破綻するので別 struct に切り出して View 経由で recurse する。
fileprivate struct TreeNodeRow: View {
	let node: TreeNode
	let depth: Int
	@Binding var collapsedDirs: Set<String>
	@Binding var selectedFilePath: String?
	@Binding var hoveredFilePath: String?
	let onSelect: (String) -> Void
	let onOpen: (String) -> Void

	var body: some View {
		if node.isDirectory {
			directoryRow
			if !collapsedDirs.contains(node.fullPath) {
				ForEach(Array(node.children.enumerated()), id: \.element.fullPath) { _, child in
					TreeNodeRow(
						node: child,
						depth: depth + 1,
						collapsedDirs: $collapsedDirs,
						selectedFilePath: $selectedFilePath,
						hoveredFilePath: $hoveredFilePath,
						onSelect: onSelect,
						onOpen: onOpen
					)
				}
			}
		} else if let file = node.file {
			FileTreeFileRow(
				file: file,
				depth: depth,
				selectedFilePath: $selectedFilePath,
				hoveredFilePath: $hoveredFilePath,
				onSelect: onSelect,
				onOpen: onOpen
			)
		}
	}

	private var directoryRow: some View {
		let isCollapsed = collapsedDirs.contains(node.fullPath)
		let fileCount = countFiles(in: node)
		return Button {
			if isCollapsed { collapsedDirs.remove(node.fullPath) } else { collapsedDirs.insert(node.fullPath) }
		} label: {
			HStack(spacing: 4) {
				Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
					.font(.system(size: 8, weight: .semibold))
					.foregroundStyle(Theme.textSecondary)
				Image(systemName: "folder")
					.font(.system(size: 10))
					.foregroundStyle(Theme.textSecondary)
				Text(node.name)
					.font(.system(size: 11))
					.foregroundStyle(Theme.textSecondary)
					.lineLimit(1)
				Spacer()
				Text("\(fileCount)")
					.font(.system(size: 9))
					.foregroundStyle(Theme.textSecondary)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.padding(.leading, CGFloat(depth) * 12)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	private func countFiles(in node: TreeNode) -> Int {
		if !node.isDirectory { return 1 }
		return node.children.reduce(0) { $0 + countFiles(in: $1) }
	}
}

fileprivate struct FileTreeFileRow: View {
	let file: ChangedFile
	let depth: Int
	@Binding var selectedFilePath: String?
	@Binding var hoveredFilePath: String?
	let onSelect: (String) -> Void
	let onOpen: (String) -> Void

	var body: some View {
		let isSelected = selectedFilePath == file.path
		let isHovered = hoveredFilePath == file.path
		HStack(spacing: 6) {
			Text(file.statusLabel)
				.font(.system(size: 9, weight: .bold, design: .monospaced))
				.foregroundStyle(file.statusColor)
				.frame(width: 14)
			Text(file.filename)
				.font(.system(size: 11))
				.foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
				.lineLimit(1)
			Spacer()
			if isHovered {
				Button { onOpen(file.path) } label: {
					Image(systemName: "arrow.up.forward.square")
						.font(.system(size: 10))
						.foregroundStyle(Theme.textSecondary)
				}
				.buttonStyle(.plain)
				.help("Open in editor")
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 3)
		.padding(.leading, CGFloat(depth) * 12)
		.background(
			RoundedRectangle(cornerRadius: 4)
				.fill(isSelected ? Theme.surfaceActive : Color.clear)
		)
		.contentShape(Rectangle())
		.onTapGesture { onSelect(file.path) }
		.onHover { hovering in hoveredFilePath = hovering ? file.path : nil }
		.id(file.path)
	}
}

struct ChangedFile {
	let status: String
	let path: String
	var diff: String = ""

	var filename: String { (path as NSString).lastPathComponent }
	var directory: String {
		let dir = (path as NSString).deletingLastPathComponent
		return dir.isEmpty ? "" : dir
	}

	var statusColor: Color {
		switch status {
		case "M", "MM": return Theme.yellow
		case "A", "??": return Theme.green
		case "D": return Theme.red
		case "R": return Theme.accent
		default: return Theme.textTertiary
		}
	}

	var statusLabel: String {
		status == "??" ? "U" : status
	}
}

struct ChangesView: View {
	let project: Project
	@ObservedObject var layoutState: ProjectLayoutState
	var onOpenFile: ((String) -> Void)? = nil
	var onDismiss: (() -> Void)? = nil
	/// filter は layoutState に永続化されてる field を直接 binding で使う。
	private var filter: DiffFilter {
		DiffFilter(
			staged: layoutState.diffFilterStaged,
			unstaged: layoutState.diffFilterUnstaged,
			committed: layoutState.diffFilterCommitted
		)
	}
	@State private var changedFiles: [ChangedFile] = []
	@State private var isLoading = false
	@State private var totalAdded = 0
	@State private var totalRemoved = 0
	@State private var selectedFilePath: String?
	@State private var collapsedDirs: Set<String> = []
	@State private var diffWebView: WKWebView?
	@State private var lastStatusHash: String = ""
	@State private var pollTimer: Timer?

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack(spacing: 10) {
				filterToggle("Staged", isOn: $layoutState.diffFilterStaged)
				filterToggle("Unstaged", isOn: $layoutState.diffFilterUnstaged)
				filterToggle("Committed", isOn: $layoutState.diffFilterCommitted)

				Theme.borderSubtle.frame(width: 1, height: 14)

				if isLoading {
					ProgressView()
						.controlSize(.small)
						.scaleEffect(0.7)
				} else {
					Text("\(changedFiles.count) files")
						.font(.system(size: 11))
						.foregroundStyle(Theme.textSecondary)
					if totalAdded > 0 {
						Text("+\(totalAdded)")
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(Theme.green)
					}
					if totalRemoved > 0 {
						Text("-\(totalRemoved)")
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(Theme.red)
					}
				}

				Spacer()

				Button {
					loadAll()
				} label: {
					Image(systemName: "arrow.clockwise")
						.font(.system(size: 11))
						.foregroundStyle(Theme.textSecondary)
				}
				.buttonStyle(.plain)

				Button {
					onDismiss?()
				} label: {
					Image(systemName: "xmark")
						.font(.system(size: 10, weight: .medium))
						.foregroundStyle(Theme.textSecondary)
				}
				.buttonStyle(.plain)
				.help("Close Changes (⇧⌘G)")
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.background(Theme.bg)

			Theme.borderSubtle.frame(height: 1)

			// Left: file tree + Right: all diffs in one scroll
			if changedFiles.isEmpty && !isLoading {
				VStack(spacing: 8) {
					Image(systemName: "checkmark.circle")
						.font(.system(size: 28, weight: .thin))
						.foregroundStyle(Theme.green)
					Text("No changes")
						.font(Theme.fontBody)
						.foregroundStyle(Theme.textTertiary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Theme.surface)
			} else {
				GeometryReader { geo in
					HStack(spacing: 0) {
						// File tree (left)
						ScrollViewReader { proxy in
							ScrollView {
								VStack(alignment: .leading, spacing: 0) {
									fileTree
								}
								.padding(.vertical, 4)
							}
							.onChange(of: selectedFilePath) {
								if let path = selectedFilePath {
									withAnimation(.easeInOut(duration: 0.2)) {
										proxy.scrollTo(path, anchor: .center)
									}
								}
							}
						}
						.frame(width: layoutState.changesTreeWidth)
						.background(Theme.bg)

						SplitDivider(
							position: $layoutState.changesTreeWidth,
							minLeft: 140,
							minRight: 280,
							availableWidth: geo.size.width
						)
						.frame(width: DividerMetrics.absoluteHitWidth)

						// Unified diff (right)
						UnifiedDiffWebView(files: changedFiles, onWebViewReady: { wv in
							diffWebView = wv
						}, onOpenFile: { path in
							openFileInEditor(path)
						}, onVisibleFileChanged: { path in
							selectedFilePath = path
						})
					}
				}
			}
		}
		.onAppear {
			loadAll()
			startPolling()
		}
		.onDisappear { stopPolling() }
		.onChange(of: layoutState.diffFilterStaged) { loadAll() }
		.onChange(of: layoutState.diffFilterUnstaged) { loadAll() }
		.onChange(of: layoutState.diffFilterCommitted) { loadAll() }
	}

	private func filterToggle(_ label: String, isOn: Binding<Bool>) -> some View {
		Button {
			isOn.wrappedValue.toggle()
		} label: {
			HStack(spacing: 4) {
				Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
					.font(.system(size: 11))
					.foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.textSecondary)
				Text(label)
					.font(.system(size: 11))
					.foregroundStyle(isOn.wrappedValue ? Theme.textPrimary : Theme.textSecondary)
			}
		}
		.buttonStyle(.plain)
	}

	// MARK: - File Tree (= 再帰 tree 構造)

	private func buildTree(from files: [ChangedFile]) -> [TreeNode] {
		// Build nested dict structure first
		var rootChildren: [String: [ChangedFile]] = [:]
		for file in files {
			let comps = file.path.split(separator: "/").map(String.init)
			if comps.isEmpty { continue }
			let topLevel = comps[0]
			rootChildren[topLevel, default: []].append(file)
		}
		var result: [TreeNode] = []
		for key in rootChildren.keys.sorted() {
			let bucket = rootChildren[key] ?? []
			let directFile = bucket.first(where: { $0.path == key })
			if bucket.count == 1, let only = directFile {
				// file at root
				result.append(TreeNode(name: only.filename, fullPath: only.path, isDirectory: false, file: only))
			} else {
				// folder
				let stripped = bucket.compactMap { f -> ChangedFile? in
					guard f.path != key else { return nil }
					let rest = String(f.path.dropFirst(key.count + 1))
					return ChangedFile(status: f.status, path: rest, diff: f.diff)
				}
				let children = buildTree(from: stripped).map { node -> TreeNode in
					// child の fullPath を親 prefix で再構成
					var n = node
					n = TreeNode(
						name: node.name,
						fullPath: "\(key)/\(node.fullPath)",
						isDirectory: node.isDirectory,
						file: node.file.map { ChangedFile(status: $0.status, path: "\(key)/\($0.path)", diff: $0.diff) },
						children: node.children.map { reattachPrefix($0, prefix: key) }
					)
					return n
				}
				result.append(TreeNode(name: key, fullPath: key, isDirectory: true, file: nil, children: children))
			}
		}
		return result
	}

	/// 再帰的に node の fullPath / file.path に prefix を付け直す。
	private func reattachPrefix(_ node: TreeNode, prefix: String) -> TreeNode {
		TreeNode(
			name: node.name,
			fullPath: "\(prefix)/\(node.fullPath)",
			isDirectory: node.isDirectory,
			file: node.file.map { ChangedFile(status: $0.status, path: "\(prefix)/\($0.path)", diff: $0.diff) },
			children: node.children.map { reattachPrefix($0, prefix: prefix) }
		)
	}

	private var fileTree: some View {
		let tree = buildTree(from: changedFiles)
		return ForEach(Array(tree.enumerated()), id: \.element.fullPath) { _, node in
			TreeNodeRow(
				node: node,
				depth: 0,
				collapsedDirs: $collapsedDirs,
				selectedFilePath: $selectedFilePath,
				hoveredFilePath: $hoveredFilePath,
				onSelect: { path in
					selectedFilePath = path
					scrollToFile(path)
				},
				onOpen: { path in openFileInEditor(path) }
			)
		}
	}

	@State private var hoveredFilePath: String?

	private func fileRow(_ file: ChangedFile) -> some View {
		let isSelected = selectedFilePath == file.path
		let isHovered = hoveredFilePath == file.path
		return HStack(spacing: 6) {
			Text(file.statusLabel)
				.font(.system(size: 9, weight: .bold, design: .monospaced))
				.foregroundStyle(file.statusColor)
				.frame(width: 14)
			Text(file.filename)
				.font(.system(size: 11))
				.foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
				.lineLimit(1)
			Spacer()
			if isHovered {
				Button {
					openFileInEditor(file.path)
				} label: {
					Image(systemName: "arrow.up.forward.square")
						.font(.system(size: 10))
						.foregroundStyle(Theme.textSecondary)
				}
				.buttonStyle(.plain)
				.help("Open in editor")
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 3)
		.background(
			RoundedRectangle(cornerRadius: 4)
				.fill(isSelected ? Theme.surfaceActive : Color.clear)
		)
		.contentShape(Rectangle())
		.onTapGesture {
			selectedFilePath = file.path
			scrollToFile(file.path)
		}
		.onHover { hovering in hoveredFilePath = hovering ? file.path : nil }
		.id(file.path)
	}

	private func openFileInEditor(_ path: String) {
		let fullPath: String
		let rootPath = project.effectivePath
		if rootPath == "." {
			fullPath = path
		} else {
			fullPath = (rootPath as NSString).appendingPathComponent(path)
		}
		onOpenFile?(fullPath)
	}

	/// Split a bulk unified diff (multiple files) into per-file diffs.
	/// Splits on "diff --git a/... b/..." headers.
	private func splitUnifiedDiff(_ bulk: String) -> [String: String] {
		var result: [String: String] = [:]
		let sections = bulk.components(separatedBy: "\ndiff --git ")
		for (i, section) in sections.enumerated() {
			let full = i == 0 ? section : "diff --git " + section
			// Extract filename from "diff --git a/path b/path"
			guard let firstLine = full.components(separatedBy: "\n").first else { continue }
			let parts = firstLine.components(separatedBy: " b/")
			guard parts.count >= 2 else { continue }
			let path = parts.last ?? ""
			if !path.isEmpty {
				result[path] = full
			}
		}
		return result
	}

	private func countLines(_ diff: String, added: inout Int, removed: inout Int) {
		for line in diff.components(separatedBy: "\n") {
			if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
			if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
		}
	}

	private func scrollToFile(_ path: String) {
		// Use CSS.escape for safe selector, fallback to data attribute query
		let b64 = Data(path.utf8).base64EncodedString()
		diffWebView?.evaluateJavaScript(
			"document.querySelector('[data-file=\"\(b64)\"]')?.scrollIntoView({behavior:'smooth',block:'start'})",
			completionHandler: nil
		)
	}

	private func startPolling() {
		stopPolling()
		pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
			checkForChanges()
		}
	}

	private func stopPolling() {
		pollTimer?.invalidate()
		pollTimer = nil
	}

	private func checkForChanges() {
		let provider = project.provider
		let rootPath = project.effectivePath
		let currentFilter = filter
		DispatchQueue.global(qos: .utility).async {
			// Build a lightweight fingerprint from git status only
			var parts: [String] = []
			if currentFilter.staged {
				let list = provider.gitChangedFiles(rootPath, args: ["--staged"])
				parts.append("S:" + list.map { "\($0.0):\($0.1)" }.joined(separator: ","))
			}
			if currentFilter.unstaged {
				let list = provider.gitChangedFiles(rootPath, args: [])
				parts.append("U:" + list.map { "\($0.0):\($0.1)" }.joined(separator: ","))
			}
			if currentFilter.committed {
				let list = provider.gitChangedFiles(rootPath, args: ["main...HEAD"])
				parts.append("C:" + list.map { "\($0.0):\($0.1)" }.joined(separator: ","))
			}
			let hash = parts.joined(separator: "|")
			DispatchQueue.main.async {
				if hash != lastStatusHash {
					lastStatusHash = hash
					loadAll()
				}
			}
		}
	}

	private func loadAll() {
		isLoading = true
		let provider = project.provider
		let rootPath = project.effectivePath
		let currentFilter = filter

		DispatchQueue.global(qos: .userInitiated).async {
			var allFiles: [String: ChangedFile] = [:] // path → file (dedup)
			var added = 0
			var removed = 0

			// Staged — single git diff --staged (all files at once)
			if currentFilter.staged {
				let stagedList = provider.gitChangedFiles(rootPath, args: ["--staged"])
				let bulkDiff = provider.gitDiffBulk(rootPath, args: ["--staged"]) ?? ""
				let splitDiffs = splitUnifiedDiff(bulkDiff)
				for (status, path) in stagedList {
					let diff = splitDiffs[path] ?? ""
					countLines(diff, added: &added, removed: &removed)
					allFiles[path] = ChangedFile(status: status, path: path, diff: diff)
				}
			}

			// Unstaged (including untracked) — single git diff
			if currentFilter.unstaged {
				let workingList = provider.gitChangedFiles(rootPath, args: [])
				let bulkDiff = provider.gitDiffBulk(rootPath, args: []) ?? ""
				let splitDiffs = splitUnifiedDiff(bulkDiff)
				for (status, path) in workingList {
					var diff = ""
					if status == "??" {
						if let content = provider.readFile(
							rootPath == "." ? path : (rootPath as NSString).appendingPathComponent(path)
						) {
							let lines = content.components(separatedBy: "\n")
							diff = "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+\($0)" }.joined(separator: "\n")
							added += lines.count
						}
					} else {
						diff = splitDiffs[path] ?? ""
						countLines(diff, added: &added, removed: &removed)
					}
					if let existing = allFiles[path] {
						allFiles[path] = ChangedFile(status: existing.status, path: path, diff: existing.diff + "\n" + diff)
					} else {
						allFiles[path] = ChangedFile(status: status, path: path, diff: diff)
					}
				}
			}

			// Committed (branch diff) — single git diff main...HEAD
			if currentFilter.committed {
				let branchList = provider.gitChangedFiles(rootPath, args: ["main...HEAD"])
				let bulkDiff = provider.gitDiffBulk(rootPath, args: ["main...HEAD"]) ?? ""
				let splitDiffs = splitUnifiedDiff(bulkDiff)
				for (status, path) in branchList {
					if allFiles[path] != nil { continue }
					let diff = splitDiffs[path] ?? ""
					countLines(diff, added: &added, removed: &removed)
					allFiles[path] = ChangedFile(status: status, path: path, diff: diff)
				}
			}

			// Sort to match file tree order: root files first, then by directory, then filename
			let files = allFiles.values.sorted {
				let dir0 = $0.directory
				let dir1 = $1.directory
				if dir0 == dir1 { return $0.filename < $1.filename }
				if dir0.isEmpty { return true }
				if dir1.isEmpty { return false }
				return dir0 < dir1
			}

			DispatchQueue.main.async {
				changedFiles = files
				totalAdded = added
				totalRemoved = removed
				isLoading = false
			}
		}
	}
}

// MARK: - Unified Diff WebView (all files in one scroll)

private struct UnifiedDiffWebView: NSViewRepresentable {
	let files: [ChangedFile]
	var onWebViewReady: ((WKWebView) -> Void)?

	var onOpenFile: ((String) -> Void)?
	var onVisibleFileChanged: ((String) -> Void)?

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "diffHandler")
		let webView = WKWebView(frame: .zero, configuration: config)
		webView.setValue(false, forKey: "drawsBackground")
		webView.loadHTMLString(buildHTML(), baseURL: nil)
		DispatchQueue.main.async { onWebViewReady?(webView) }
		return webView
	}

	func makeCoordinator() -> DiffCoordinator { DiffCoordinator(onOpenFile: onOpenFile, onVisibleFileChanged: onVisibleFileChanged) }

	func updateNSView(_ nsView: WKWebView, context: Context) {
		let newHash = files.map(\.path).joined(separator: ",")
		if context.coordinator.lastHash != newHash {
			context.coordinator.lastHash = newHash
			// Reload で scroll position が初期化されるのを防ぐため、reload 前に Y を
			// 取得 → reload 完了後に同 Y へ復元する。Polling 更新時の UX 維持。
			nsView.evaluateJavaScript("window.scrollY") { result, _ in
				let scrollY = (result as? Double) ?? 0
				nsView.loadHTMLString(buildHTML(), baseURL: nil)
				// 復元: page reload 完了後に scrollTo。WKWebView.reload は async なので
				// didFinish navigation 経由が理想だが、簡単のため delay で対応。
				// 100ms で大半の reload が終わる。複数 retry で取りこぼし防止。
				let restoreScript = "window.scrollTo(0, \(scrollY))"
				for delay in [0.1, 0.25, 0.5] {
					DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
						nsView.evaluateJavaScript(restoreScript)
					}
				}
			}
		}
		DispatchQueue.main.async { onWebViewReady?(nsView) }
	}

	class DiffCoordinator: NSObject, WKScriptMessageHandler {
		var lastHash: String = ""
		var onOpenFile: ((String) -> Void)?
		var onVisibleFileChanged: ((String) -> Void)?

		init(onOpenFile: ((String) -> Void)?, onVisibleFileChanged: ((String) -> Void)?) {
			self.onOpenFile = onOpenFile
			self.onVisibleFileChanged = onVisibleFileChanged
		}

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
				  let type = body["type"] as? String else { return }
			if type == "openFile", let path = body["path"] as? String {
				DispatchQueue.main.async { [weak self] in
					self?.onOpenFile?(path)
				}
			} else if type == "visibleFile", let b64 = body["file"] as? String {
				if let data = Data(base64Encoded: b64), let path = String(data: data, encoding: .utf8) {
					DispatchQueue.main.async { [weak self] in
						self?.onVisibleFileChanged?(path)
					}
				}
			}
		}
	}

	private func buildHTML() -> String {
		var sections = ""
		for file in files {
			sections += buildFileSection(file)
		}

		return """
		<!DOCTYPE html>
		<html>
		<head>
		<meta charset="UTF-8">
		<style>
		* { margin: 0; padding: 0; box-sizing: border-box; }
		body {
			background: #141418;
			color: #cdd6f4;
			font-family: -apple-system, BlinkMacSystemFont, sans-serif;
			font-size: 13px;
		}
		.file-section {
			margin-bottom: 16px;
			border: 1px solid #313244;
			border-radius: 8px;
			overflow: hidden;
			background: #1e1e2e;
		}
		.file-section:last-child {
			margin-bottom: 24px;
		}
		.file-header {
			display: flex;
			align-items: center;
			gap: 8px;
			padding: 10px 14px;
			background: #252534;
			border-bottom: 1px solid #313244;
			cursor: pointer;
			-webkit-user-select: none;
			user-select: none;
			position: sticky;
			top: 0;
			z-index: 10;
		}
		.file-header:hover {
			background: #2a2a38;
		}
		.chevron {
			font-size: 10px;
			color: #7f849c;
			transition: transform 0.15s;
			width: 12px;
		}
		.chevron.collapsed {
			transform: rotate(-90deg);
		}
		.status-badge {
			font-family: 'SF Mono', Menlo, monospace;
			font-size: 10px;
			font-weight: 700;
			padding: 1px 4px;
			border-radius: 3px;
		}
		.status-M { color: #f9e2af; background: rgba(249, 226, 175, 0.15); }
		.status-A, .status-U { color: #a6e3a1; background: rgba(166, 227, 161, 0.15); }
		.status-D { color: #f38ba8; background: rgba(243, 139, 168, 0.15); }
		.status-R { color: #89b4fa; background: rgba(137, 180, 250, 0.15); }
		.filename {
			font-size: 12px;
			font-weight: 500;
			color: #cdd6f4;
			flex: 1;
			overflow: hidden;
			text-overflow: ellipsis;
			white-space: nowrap;
			direction: rtl;
			text-align: left;
		}
		.open-btn {
			font-size: 10px;
			color: #7f849c;
			cursor: pointer;
			padding: 2px 6px;
			border-radius: 4px;
			border: 1px solid #313244;
			background: transparent;
			margin-left: auto;
		}
		.open-btn:hover {
			color: #89b4fa;
			border-color: #89b4fa;
		}
		.expand-row {
			background: rgba(137, 180, 250, 0.04);
			cursor: pointer;
		}
		.expand-row:hover {
			background: rgba(137, 180, 250, 0.10);
		}
		.expand-row td {
			text-align: center;
			color: #7f849c;
			font-size: 11px;
			padding: 3px 0;
		}
		.diff-table {
			width: 100%;
			border-collapse: collapse;
			font-family: 'SF Mono', Menlo, Monaco, monospace;
			font-size: 12px;
			line-height: 1.5;
		}
		.diff-table tr.add { background: rgba(166, 227, 161, 0.10); }
		.diff-table tr.del { background: rgba(243, 139, 168, 0.10); }
		.diff-table tr.hunk {
			background: rgba(137, 180, 250, 0.06);
		}
		.diff-table td.ln {
			width: 40px;
			min-width: 40px;
			text-align: right;
			padding: 0 6px;
			color: #6c7086;
			-webkit-user-select: none;
			user-select: none;
			border-right: 1px solid #252530;
			font-size: 11px;
		}
		.diff-table td.code {
			padding: 0 12px;
			white-space: pre-wrap;
			word-break: break-all;
		}
		.diff-table tr.add td.code { color: #a6e3a1; }
		.diff-table tr.del td.code { color: #f38ba8; }
		.diff-table tr.hunk td.code { color: #89b4fa; font-size: 11px; }
		.diff-body { overflow: hidden; transition: max-height 0.2s ease; }
		.diff-body.collapsed { max-height: 0 !important; }
		.empty-diff {
			padding: 16px;
			color: #7f849c;
			font-style: italic;
			text-align: center;
		}
		</style>
		</head>
		<body>
		<div style="padding: 12px;">
		\(sections)
		</div>
		<script>
		document.querySelectorAll('.file-header').forEach(function(hdr) {
			hdr.addEventListener('click', function() {
				var body = hdr.nextElementSibling;
				var chevron = hdr.querySelector('.chevron');
				body.classList.toggle('collapsed');
				chevron.classList.toggle('collapsed');
			});
		});
		// Track which file section is currently visible
		var observer = new IntersectionObserver(function(entries) {
			for (var i = 0; i < entries.length; i++) {
				if (entries[i].isIntersecting) {
					var file = entries[i].target.getAttribute('data-file');
					if (file) {
						window.webkit.messageHandlers.diffHandler.postMessage({type:'visibleFile', file: file});
					}
					break;
				}
			}
		}, {rootMargin: '-10% 0px -80% 0px'});
		document.querySelectorAll('.file-section').forEach(function(el) {
			observer.observe(el);
		});
		</script>
		</body>
		</html>
		"""
	}

	private func buildFileSection(_ file: ChangedFile) -> String {
		let filename = (file.path as NSString).lastPathComponent
		let dir = (file.path as NSString).deletingLastPathComponent
		let escapedFilename = escapeHTML(filename)
		let escapedDir = escapeHTML(dir.isEmpty ? "" : dir + "/")
		let statusLabel = file.status == "??" ? "U" : escapeHTML(file.status)
		let statusClass = file.status == "??" ? "U" : file.status

		let diffLines = buildDiffRows(file.diff)

		let b64 = Data(file.path.utf8).base64EncodedString()
		let escapedFullPath = escapeHTML(file.path)
		return """
		<div class="file-section" data-file="\(b64)">
			<div class="file-header">
				<span class="chevron">▼</span>
				<span class="status-badge status-\(statusClass)">\(statusLabel)</span>
				<span class="filename">\(escapedFullPath)</span>
				<button class="open-btn" onclick="event.stopPropagation();window.webkit.messageHandlers.diffHandler.postMessage({type:'openFile',path:'\(escapedFullPath)'})">Open ↗</button>
			</div>
			<div class="diff-body">
				\(diffLines.isEmpty ? "<div class=\"empty-diff\">No diff available</div>" : "<table class=\"diff-table\">\(diffLines)</table>")
			</div>
		</div>
		"""
	}

	private func buildDiffRows(_ diffText: String) -> String {
		let lines = diffText.components(separatedBy: "\n")
		var html = ""
		var oldLine = 0
		var newLine = 0
		var prevOldEnd = 0
		var prevNewEnd = 0
		var isFirstHunk = true

		for line in lines {
			let escaped = escapeHTML(line)

			if line.hasPrefix("@@") {
				let parts = line.components(separatedBy: " ")
				if parts.count >= 3 {
					let oldComps = parts[1].dropFirst().split(separator: ",")
					let newComps = parts[2].dropFirst().split(separator: ",")
					let newOldStart = Int(oldComps[0]) ?? 0
					let newNewStart = Int(newComps[0]) ?? 0

					// Show "expand" row for skipped lines between hunks
					if !isFirstHunk && newOldStart > prevOldEnd + 1 {
						let skipped = newOldStart - prevOldEnd - 1
						html += "<tr class=\"expand-row\"><td colspan=\"3\">⋯ \(skipped) lines hidden ⋯</td></tr>"
					}
					isFirstHunk = false

					oldLine = newOldStart
					newLine = newNewStart
				}
				html += "<tr class=\"hunk\"><td class=\"ln\"></td><td class=\"ln\"></td><td class=\"code\">\(escaped)</td></tr>"
			} else if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
				continue
			} else if line.hasPrefix("+") {
				html += "<tr class=\"add\"><td class=\"ln\"></td><td class=\"ln\">\(newLine)</td><td class=\"code\">\(escaped)</td></tr>"
				newLine += 1
				prevNewEnd = newLine - 1
			} else if line.hasPrefix("-") {
				html += "<tr class=\"del\"><td class=\"ln\">\(oldLine)</td><td class=\"ln\"></td><td class=\"code\">\(escaped)</td></tr>"
				oldLine += 1
				prevOldEnd = oldLine - 1
			} else if !line.isEmpty {
				html += "<tr><td class=\"ln\">\(oldLine)</td><td class=\"ln\">\(newLine)</td><td class=\"code\">\(escaped)</td></tr>"
				oldLine += 1
				newLine += 1
				prevOldEnd = oldLine - 1
				prevNewEnd = newLine - 1
			}
		}
		return html
	}

	private func escapeHTML(_ s: String) -> String {
		s.replacingOccurrences(of: "&", with: "&amp;")
		 .replacingOccurrences(of: "<", with: "&lt;")
		 .replacingOccurrences(of: ">", with: "&gt;")
	}
}
