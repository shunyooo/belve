import SwiftUI

struct TerminalPaneView: View {
	var body: some View {
		VStack(spacing: 8) {
			Image(systemName: "terminal")
				.font(.system(size: 28, weight: .thin))
				.foregroundStyle(Theme.textTertiary)
			Text("Terminal")
				.font(Theme.fontMono)
				.foregroundStyle(Theme.textTertiary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Theme.bg)
	}
}
