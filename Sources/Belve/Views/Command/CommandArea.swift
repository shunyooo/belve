import SwiftUI

enum SplitDirection {
	case horizontal, vertical
}

class PaneNode: ObservableObject, Identifiable {
	let id = UUID()
	@Published var children: [PaneNode]?
	@Published var splitDirection: SplitDirection?

	var isLeaf: Bool { children == nil }

	func split(_ direction: SplitDirection) {
		guard isLeaf else { return }
		splitDirection = direction
		children = [PaneNode(), PaneNode()]
		// Move this terminal's identity to first child
	}
}

class CommandAreaState: ObservableObject {
	@Published var root = PaneNode()

	func splitActive(_ direction: SplitDirection) {
		// For now, split the root or first leaf
		if root.isLeaf {
			root.split(direction)
			objectWillChange.send()
		}
	}
}

struct CommandArea: View {
	let project: Project
	@ObservedObject var state: CommandAreaState

	var body: some View {
		PaneTreeView(node: state.root, project: project)
			.background(Theme.bg)
	}
}

struct PaneTreeView: View {
	@ObservedObject var node: PaneNode
	let project: Project

	var body: some View {
		if node.isLeaf {
			TerminalPaneView(project: project)
				.id(node.id)
		} else if let children = node.children, let direction = node.splitDirection {
			switch direction {
			case .vertical:
				VStack(spacing: 0) {
					ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
						if index > 0 {
							Theme.border
								.frame(height: 1)
						}
						PaneTreeView(node: child, project: project)
					}
				}
			case .horizontal:
				HStack(spacing: 0) {
					ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
						if index > 0 {
							Theme.border
								.frame(width: 1)
						}
						PaneTreeView(node: child, project: project)
					}
				}
			}
		}
	}
}
