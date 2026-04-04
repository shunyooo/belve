import SwiftUI

struct TerminalPane: Identifiable {
	let id = UUID()
}

class CommandAreaState: ObservableObject {
	@Published var panes: [TerminalPane] = [TerminalPane()]

	func split() {
		panes.append(TerminalPane())
	}

	func closeLastPane() {
		if panes.count > 1 {
			panes.removeLast()
		}
	}
}

struct CommandArea: View {
	let project: Project
	@ObservedObject var state: CommandAreaState

	var body: some View {
		VStack(spacing: 0) {
			ForEach(Array(state.panes.enumerated()), id: \.element.id) { index, pane in
				if index > 0 {
					Theme.border
						.frame(height: 1)
				}
				TerminalPaneView(project: project)
					.id(pane.id)
			}
		}
		.background(Theme.bg)
	}
}
