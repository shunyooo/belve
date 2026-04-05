import SwiftUI

enum SplitDirection {
	case horizontal, vertical
}

class PaneNode: ObservableObject, Identifiable {
	let id = UUID()
	@Published var children: [PaneNode]?
	@Published var splitDirection: SplitDirection?
	@Published var splitRatio: CGFloat = 0.5

	var isLeaf: Bool { children == nil }

	func split(_ direction: SplitDirection) {
		guard isLeaf else { return }
		splitDirection = direction
		splitRatio = 0.5
		children = [PaneNode(), PaneNode()]
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
			GhosttyTerminalView(project: project, paneId: node.id.uuidString)
				.id(node.id)
		} else if let children = node.children, children.count == 2,
				  let direction = node.splitDirection {
			GeometryReader { geo in
				let totalSize = direction == .vertical ? geo.size.height : geo.size.width
				let dividerThickness: CGFloat = 1
				let available = totalSize - dividerThickness
				let firstSize = available * node.splitRatio
				let secondSize = available * (1 - node.splitRatio)

				switch direction {
				case .vertical:
					VStack(spacing: 0) {
						PaneTreeView(node: children[0], project: project)
							.frame(height: firstSize)
						PaneDivider(
							direction: .vertical,
							availableSize: available,
							ratio: $node.splitRatio
						)
						PaneTreeView(node: children[1], project: project)
							.frame(height: secondSize)
					}
				case .horizontal:
					HStack(spacing: 0) {
						PaneTreeView(node: children[0], project: project)
							.frame(width: firstSize)
						PaneDivider(
							direction: .horizontal,
							availableSize: available,
							ratio: $node.splitRatio
						)
						PaneTreeView(node: children[1], project: project)
							.frame(width: secondSize)
					}
				}
			}
		}
	}
}

struct PaneDivider: View {
	let direction: SplitDirection
	let availableSize: CGFloat
	@Binding var ratio: CGFloat
	@State private var isDragging = false
	@State private var ratioAtDragStart: CGFloat = 0

	var body: some View {
		let isVertical = direction == .vertical
		Rectangle()
			.fill(isDragging ? Theme.border : Theme.borderSubtle)
			.frame(width: isVertical ? nil : 1, height: isVertical ? 1 : nil)
			.contentShape(Rectangle().inset(by: -3))
			.onHover { hovering in
				if hovering {
					(isVertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
				} else {
					NSCursor.pop()
				}
			}
			.gesture(
				DragGesture(minimumDistance: 1, coordinateSpace: .global)
					.onChanged { value in
						if !isDragging {
							isDragging = true
							ratioAtDragStart = ratio
						}
						let translation = isVertical ? value.translation.height : value.translation.width
						let newRatio = ratioAtDragStart + translation / availableSize
						ratio = max(0.15, min(0.85, newRatio))
					}
					.onEnded { _ in
						isDragging = false
					}
			)
	}
}
