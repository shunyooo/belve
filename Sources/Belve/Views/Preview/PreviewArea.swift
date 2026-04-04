import SwiftUI

struct OpenFile: Equatable {
	let path: String
	let content: String
}

struct PreviewArea: View {
	let project: Project
	@Binding var openFile: OpenFile?
	@State private var showFileTree = true
	@State private var fileTreeWidth: CGFloat = 200

	private var rootPath: String {
		project.remotePath ?? NSHomeDirectory()
	}

	var body: some View {
		HStack(spacing: 0) {
			// File tree
			if showFileTree {
				VStack(spacing: 0) {
					// Header
					HStack {
						Text("FILES")
							.font(.system(size: 10, weight: .semibold))
							.foregroundStyle(Theme.textTertiary)
							.tracking(0.8)
						Spacer()
					}
					.padding(.horizontal, 10)
					.padding(.vertical, 5)
					.background(Theme.bg)

					Theme.borderSubtle
						.frame(height: 1)

					FileTreeView(
						project: project,
						rootPath: rootPath,
						onFileSelect: { path in
							loadFile(at: path)
						}
					)
				}
				.frame(width: fileTreeWidth)

				Theme.borderSubtle
					.frame(width: 1)
			}

			// Editor / placeholder
			if let file = openFile {
				VStack(spacing: 0) {
					// File tab
					HStack(spacing: 6) {
						Image(systemName: "doc.text")
							.font(.system(size: 10))
							.foregroundStyle(Theme.textSecondary)
						Text((file.path as NSString).lastPathComponent)
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(Theme.textPrimary)
							.lineLimit(1)
						Spacer()
						Button {
							openFile = nil
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

					if file.path.hasSuffix(".md") {
						MarkdownEditorView(content: file.content) { _ in }
					} else {
						CodeEditorView(
							filename: file.path,
							content: file.content
						) { _ in }
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
			}
		}
	}

	private func loadFile(at path: String) {
		DispatchQueue.global().async {
			if let content = FileService.readFile(path: path, sshHost: project.sshHost) {
				DispatchQueue.main.async {
					openFile = OpenFile(path: path, content: content)
				}
			}
		}
	}
}
