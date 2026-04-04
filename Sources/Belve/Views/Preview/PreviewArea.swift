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
	@State private var isDirty = false
	@State private var editedContent: String = ""

	private var rootPath: String {
		project.remotePath ?? NSHomeDirectory()
	}

	var body: some View {
		HStack(spacing: 0) {
			// File tree
			if showFileTree {
				FileTreeView(
					project: project,
					rootPath: rootPath,
					onFileSelect: { path in
						loadFile(at: path)
					}
				)
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
							MarkdownEditorView(content: file.content) { newContent in
								editedContent = newContent
								isDirty = newContent != file.content
							}
						case .image, .pdf:
							MediaPreviewView(path: file.path, sshHost: project.sshHost)
						case .code, .unknown:
							CodeEditorView(
								filename: file.path,
								content: file.content
							) { newContent in
								editedContent = newContent
								isDirty = newContent != file.content
							}
						}
					}
					.id(file.path)
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
		.onChange(of: openFile) {
			isDirty = false
			editedContent = openFile?.content ?? ""
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveFileSave)) { _ in
			saveCurrentFile()
		}
	}

	private func loadFile(at path: String) {
		NSLog("[Belve] loadFile: \(path)")
		let fileType = FileType.detect(path: path)

		if fileType == .image || fileType == .pdf {
			DispatchQueue.main.async {
				openFile = OpenFile(path: path, content: "")
			}
			return
		}

		DispatchQueue.global().async {
			if let content = FileService.readFile(path: path, sshHost: project.sshHost) {
				NSLog("[Belve] File loaded: \(path), \(content.count) chars")
				DispatchQueue.main.async {
					openFile = OpenFile(path: path, content: content)
				}
			} else {
				NSLog("[Belve] Failed to read file: \(path)")
			}
		}
	}

	func saveCurrentFile() {
		guard let file = openFile, isDirty else { return }
		DispatchQueue.global().async {
			let success = FileService.writeFile(path: file.path, content: editedContent, sshHost: project.sshHost)
			DispatchQueue.main.async {
				if success {
					openFile = OpenFile(path: file.path, content: editedContent)
					isDirty = false
				}
			}
		}
	}
}
