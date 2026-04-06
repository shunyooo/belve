import SwiftUI

enum SplitDirection {
	case horizontal, vertical
}

class PaneNode: ObservableObject, Identifiable {
	let id: UUID
	@Published var children: [PaneNode]?
	@Published var splitDirection: SplitDirection?
	@Published var splitRatio: CGFloat = 0.5

	/// Cached terminal NSView — survives split operations
	var terminalView: GhosttyTerminalNSView?

	init(id: UUID = UUID()) {
		self.id = id
	}

	var isLeaf: Bool { children == nil }

	func split(_ direction: SplitDirection) {
		guard isLeaf else { return }
		// Move this node's terminal view to first child
		let existing = PaneNode(id: self.id)
		existing.terminalView = self.terminalView
		self.terminalView = nil
		let newPane = PaneNode()
		splitDirection = direction
		splitRatio = 0.5
		children = [existing, newPane]
	}
}

class CommandAreaState: ObservableObject {
	@Published var root = PaneNode()
	@Published var activePaneId: UUID?

	func splitActive(_ direction: SplitDirection) {
		// Split the active pane, or fall back to first leaf
		let targetId = activePaneId ?? firstLeaf(root)?.id
		guard let targetId else { return }
		if splitNode(targetId, direction: direction, in: root) {
			objectWillChange.send()
		}
	}

	private func splitNode(_ id: UUID, direction: SplitDirection, in node: PaneNode) -> Bool {
		if node.id == id && node.isLeaf {
			node.split(direction)
			return true
		}
		for child in node.children ?? [] {
			if splitNode(id, direction: direction, in: child) {
				return true
			}
		}
		return false
	}

	func closeActivePane() {
		let targetId = activePaneId ?? firstLeaf(root)?.id
		guard let targetId else { return }
		removePane(targetId)
	}

	func removePane(_ id: UUID) {
		if root.id == id && root.isLeaf {
			// Last pane — don't remove, just reset
			return
		}
		if removeNode(id, from: root, parent: nil) {
			objectWillChange.send()
		}
	}

	private func removeNode(_ id: UUID, from node: PaneNode, parent: PaneNode?) -> Bool {
		guard let children = node.children else { return false }
		for (index, child) in children.enumerated() {
			if child.id == id && child.isLeaf {
				// Replace parent with the sibling
				let sibling = children[1 - index]
				node.children = sibling.children
				node.splitDirection = sibling.splitDirection
				node.splitRatio = sibling.splitRatio
				// If sibling was a leaf, this node becomes a leaf
				return true
			}
			if removeNode(id, from: child, parent: node) {
				return true
			}
		}
		return false
	}

	func findNode(_ paneId: String) -> PaneNode? {
		guard let uuid = UUID(uuidString: paneId) else { return nil }
		return findNodeById(uuid, in: root)
	}

	private func findNodeById(_ id: UUID, in node: PaneNode) -> PaneNode? {
		if node.id == id { return node }
		for child in node.children ?? [] {
			if let found = findNodeById(id, in: child) { return found }
		}
		return nil
	}

	private func firstLeaf(_ node: PaneNode) -> PaneNode? {
		if node.isLeaf { return node }
		for child in node.children ?? [] {
			if let leaf = firstLeaf(child) { return leaf }
		}
		return nil
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
			GhosttyTerminalView(project: project, paneId: node.id.uuidString, cachedView: node.terminalView)
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
