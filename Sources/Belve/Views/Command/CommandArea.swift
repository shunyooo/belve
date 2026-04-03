import SwiftUI

struct CommandArea: View {
	let project: Project

	var body: some View {
		TerminalPaneView()
			.background(Theme.bg)
	}
}
