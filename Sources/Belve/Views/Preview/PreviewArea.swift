import SwiftUI

struct OpenFile: Equatable {
	let path: String
	let content: String
}

struct PreviewArea: View {
	let project: Project
	@ObservedObject var layoutState: ProjectLayoutState
	@Binding var openFile: OpenFile?
	@State private var isDirty = false
	@State private var editedContent: String = ""

	private var rootPath: String {
		project.effectivePath
	}

	var body: some View {
		GeometryReader { geo in
			HStack(spacing: 0) {
				if layoutState.showFileTree {
					FileTreeView(
						project: project,
						rootPath: rootPath,
						onFileSelect: { path in
							loadFile(at: path)
						}
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

				editorContent
			}
		}
		.onChange(of: openFile) {
			isDirty = false
			editedContent = openFile?.content ?? ""
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveFileSave)) { _ in
			saveCurrentFile()
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveFileDeleted)) { notif in
			if let deletedPaths = notif.object as? [String],
			   let current = openFile?.path,
			   deletedPaths.contains(current) {
				openFile = nil
			}
		}
	}

	@ViewBuilder
	private var editorContent: some View {
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

	private func loadFile(at path: String) {
		NSLog("[Belve] loadFile: \(path)")
		let fileType = FileType.detect(path: path)

		if fileType == .image || fileType == .pdf {
			DispatchQueue.main.async {
				openFile = OpenFile(path: path, content: "")
			}
			return
		}

		let ctx = project.executionContext
		DispatchQueue.global().async {
			if let content = ctx.readFile(path) {
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
		let ctx = project.executionContext
		DispatchQueue.global().async {
			let success = ctx.writeFile(file.path, content: editedContent)
			DispatchQueue.main.async {
				if success {
					openFile = OpenFile(path: file.path, content: editedContent)
					isDirty = false
				}
			}
		}
	}
}
