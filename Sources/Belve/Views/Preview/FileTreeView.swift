import SwiftUI

class FileTreeState: ObservableObject {
	@Published var items: [FileItem] = []
	@Published var expandedPaths: Set<String> = []
	@Published var childrenCache: [String: [FileItem]] = [:]
	@Published var focusedPath: String?

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
			expandedPaths.remove(path)
		} else {
			expandedPaths.insert(path)
			if childrenCache[path] == nil {
				DispatchQueue.global().async {
					let children = project.executionContext.listDirectory(path)
					DispatchQueue.main.async {
						NSLog("[Belve] Loaded \(children.count) children for \(path)")
						self.childrenCache[path] = children
					}
				}
			}
		}
	}
}

struct FileTreeView: View {
	let project: Project
	let rootPath: String
	let onFileSelect: (String) -> Void
	@StateObject private var state = FileTreeState()

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				ForEach(state.items) { item in
					FileTreeRow(
						item: item,
						depth: 0,
						state: state,
						project: project,
						onFileSelect: onFileSelect
					)
				}
			}
			.padding(.vertical, 4)
		}
		.background(Theme.surface)
		.focusable()
		.onKeyPress(.upArrow) {
			state.moveFocusUp()
			return .handled
		}
		.onKeyPress(.downArrow) {
			state.moveFocusDown()
			return .handled
		}
		.onKeyPress(.rightArrow) {
			if let path = state.focusedPath {
				let visible = state.visibleItems()
				if let item = visible.first(where: { $0.path == path }), item.isDirectory {
					if !state.expandedPaths.contains(path) {
						state.toggle(path: path, project: project)
					}
				}
			}
			return .handled
		}
		.onKeyPress(.leftArrow) {
			if let path = state.focusedPath {
				if state.expandedPaths.contains(path) {
					state.expandedPaths.remove(path)
				}
			}
			return .handled
		}
		.onKeyPress(.return) {
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
		.onAppear {
			DispatchQueue.global().async {
				let result = project.executionContext.listDirectory(rootPath)
				DispatchQueue.main.async {
					state.items = result
					state.focusedPath = result.first?.path
				}
			}
		}
	}
}

struct FileTreeRow: View {
	let item: FileItem
	let depth: Int
	@ObservedObject var state: FileTreeState
	let project: Project
	let onFileSelect: (String) -> Void
	@State private var isHovering = false

	private var isFocused: Bool {
		state.focusedPath == item.path
	}

	private var isExpanded: Bool {
		state.expandedPaths.contains(item.path)
	}

	private var children: [FileItem] {
		state.childrenCache[item.path] ?? []
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Button {
				if item.isDirectory {
					state.toggle(path: item.path, project: project)
				} else {
					onFileSelect(item.path)
				}
			} label: {
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

					Image(systemName: item.isDirectory ? "folder.fill" : fileIcon(item.name))
						.font(.system(size: 11))
						.foregroundStyle(item.isDirectory ? Theme.yellow : Theme.textSecondary)

					Text(item.name)
						.font(.system(size: 12))
						.foregroundStyle(Theme.textPrimary)
						.lineLimit(1)

					Spacer()
				}
				.padding(.leading, CGFloat(depth) * 14 + 6)
				.padding(.vertical, 3)
				.padding(.trailing, 6)
				.background(isFocused ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
			}
			.buttonStyle(.plain)
			.accessibilityLabel(item.name)
			.onHover { hovering in
				isHovering = hovering
			}

			// Children
			if item.isDirectory, isExpanded {
				ForEach(children) { child in
					FileTreeRow(
						item: child,
						depth: depth + 1,
						state: state,
						project: project,
						onFileSelect: onFileSelect
					)
				}
			}
		}
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
