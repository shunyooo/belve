import SwiftUI

struct PreviewArea: View {
	let project: Project

	var body: some View {
		// Will show file tree + editor/markdown/web based on opened file
		// For now, empty state
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
