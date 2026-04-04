import SwiftUI

struct OpenFile: Equatable {
	let path: String
	let content: String
}

struct PreviewArea: View {
	let project: Project
	@Binding var openFile: OpenFile?

	var body: some View {
		if let file = openFile {
			VStack(spacing: 0) {
				// File tab
				HStack(spacing: 6) {
					Image(systemName: "doc.text")
						.font(.system(size: 10))
						.foregroundStyle(Theme.textSecondary)
					Text(file.path.components(separatedBy: "/").last ?? file.path)
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

				CodeEditorView(
					filename: file.path,
					content: file.content
				) { newContent in
					NSLog("[Belve] Content changed, \(newContent.count) chars")
				}
			}
		} else {
			VStack(spacing: 8) {
				Image(systemName: "doc.text.magnifyingglass")
					.font(.system(size: 28, weight: .thin))
					.foregroundStyle(Theme.textTertiary)
				Text("Open a file to preview")
					.font(Theme.fontBody)
					.foregroundStyle(Theme.textTertiary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(Theme.surface)
		}
	}
}
