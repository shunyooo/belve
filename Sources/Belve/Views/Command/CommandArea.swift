import SwiftUI

struct CommandArea: View {
	let project: Project

	var body: some View {
		TerminalPaneView(project: project)
			.background(Theme.bg)
	}
}
