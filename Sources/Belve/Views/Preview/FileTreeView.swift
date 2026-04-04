import SwiftUI

struct FileTreeView: View {
	let project: Project
	let rootPath: String
	let onFileSelect: (String) -> Void
	@State private var items: [FileItem] = []
	@State private var expandedPaths: Set<String> = []

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				ForEach(items) { item in
					FileTreeRow(
						item: item,
						depth: 0,
						expandedPaths: $expandedPaths,
						project: project,
						onFileSelect: onFileSelect,
						onToggleExpand: { path in
							toggleExpand(item: item, path: path)
						}
					)
				}
			}
			.padding(.vertical, 4)
		}
		.background(Theme.surface)
		.onAppear {
			loadRoot()
		}
	}

	private func loadRoot() {
		DispatchQueue.global().async {
			let result = FileService.listDirectory(path: rootPath, sshHost: project.sshHost)
			DispatchQueue.main.async {
				items = result
			}
		}
	}

	private func toggleExpand(item: FileItem, path: String) {
		if expandedPaths.contains(path) {
			expandedPaths.remove(path)
		} else {
			expandedPaths.insert(path)
			// Load children
			DispatchQueue.global().async {
				let children = FileService.listDirectory(path: path, sshHost: project.sshHost)
				DispatchQueue.main.async {
					updateChildren(for: path, children: children, in: &items)
				}
			}
		}
	}

	private func updateChildren(for path: String, children: [FileItem], in items: inout [FileItem]) {
		for i in items.indices {
			if items[i].path == path {
				items[i].children = children
				return
			}
			if var sub = items[i].children {
				updateChildren(for: path, children: children, in: &sub)
				items[i].children = sub
			}
		}
	}
}

struct FileTreeRow: View {
	let item: FileItem
	let depth: Int
	@Binding var expandedPaths: Set<String>
	let project: Project
	let onFileSelect: (String) -> Void
	let onToggleExpand: (String) -> Void
	@State private var isHovering = false

	private var isExpanded: Bool {
		expandedPaths.contains(item.path)
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
			.background(isHovering ? Theme.surfaceHover : Color.clear)
			.onHover { hovering in
				isHovering = hovering
			}
			.onTapGesture {
				if item.isDirectory {
					onToggleExpand(item.path)
				} else {
					onFileSelect(item.path)
				}
			}

			// Children
			if item.isDirectory, isExpanded, let children = item.children {
				ForEach(children) { child in
					FileTreeRow(
						item: child,
						depth: depth + 1,
						expandedPaths: $expandedPaths,
						project: project,
						onFileSelect: onFileSelect,
						onToggleExpand: onToggleExpand
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
