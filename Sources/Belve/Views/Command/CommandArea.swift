import SwiftUI

enum SplitDirection {
	case horizontal, vertical
}

class PaneNode: ObservableObject, Identifiable {
	let id: UUID
	let paneIndex: Int
	@Published var children: [PaneNode]?
	@Published var splitDirection: SplitDirection?
	@Published var splitRatio: CGFloat = 0.5

	init(id: UUID = UUID(), paneIndex: Int = 0) {
		self.id = id
		self.paneIndex = paneIndex
	}

	var isLeaf: Bool { children == nil }
}

// MARK: - Layout Calculation

struct PaneLayout {
	struct Pane: Identifiable {
		let id: UUID
		let paneIndex: Int
		let rect: CGRect
	}
	struct DividerItem: Identifiable {
		let id: UUID
		let direction: SplitDirection
		let rect: CGRect
		let availableSize: CGFloat
	}
	let panes: [Pane]
	let dividers: [DividerItem]
}

// MARK: - Command Area State

class CommandAreaState: ObservableObject {
	@Published var root = PaneNode(paneIndex: 0)
	@Published var activePaneId: UUID?
	private var nextPaneIndex = 1

	func splitActive(_ direction: SplitDirection) {
		let targetId = activePaneId ?? firstLeaf(root)?.id
		guard let targetId else { return }
		if splitNode(targetId, direction: direction, in: root) {
			objectWillChange.send()
		}
	}

	private func splitNode(_ id: UUID, direction: SplitDirection, in node: PaneNode) -> Bool {
		if node.id == id && node.isLeaf {
			let existing = PaneNode(id: node.id, paneIndex: node.paneIndex)
			let newPane = PaneNode(paneIndex: nextPaneIndex)
			nextPaneIndex += 1
			node.splitDirection = direction
			node.splitRatio = 0.5
			node.children = [existing, newPane]
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
				let sibling = children[1 - index]
				node.children = sibling.children
				node.splitDirection = sibling.splitDirection
				node.splitRatio = sibling.splitRatio
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

	func findNodeById(_ id: UUID, in node: PaneNode) -> PaneNode? {
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

	// MARK: - Flat Layout Calculation

	func calculateLayout(in size: CGSize) -> PaneLayout {
		var panes: [PaneLayout.Pane] = []
		var dividers: [PaneLayout.DividerItem] = []
		let dividerThickness: CGFloat = 1

		func walk(_ node: PaneNode, rect: CGRect) {
			if node.isLeaf {
				panes.append(.init(id: node.id, paneIndex: node.paneIndex, rect: rect))
				return
			}
			guard let children = node.children, children.count == 2,
				  let direction = node.splitDirection else { return }

			let totalSize = direction == .vertical ? rect.height : rect.width
			let available = totalSize - dividerThickness
			let firstSize = available * node.splitRatio

			switch direction {
			case .vertical:
				walk(children[0], rect: CGRect(
					x: rect.minX, y: rect.minY,
					width: rect.width, height: firstSize))
				dividers.append(.init(
					id: node.id, direction: .vertical,
					rect: CGRect(x: rect.minX, y: rect.minY + firstSize, width: rect.width, height: dividerThickness),
					availableSize: available))
				walk(children[1], rect: CGRect(
					x: rect.minX, y: rect.minY + firstSize + dividerThickness,
					width: rect.width, height: available - firstSize))
			case .horizontal:
				walk(children[0], rect: CGRect(
					x: rect.minX, y: rect.minY,
					width: firstSize, height: rect.height))
				dividers.append(.init(
					id: node.id, direction: .horizontal,
					rect: CGRect(x: rect.minX + firstSize, y: rect.minY, width: dividerThickness, height: rect.height),
					availableSize: available))
				walk(children[1], rect: CGRect(
					x: rect.minX + firstSize + dividerThickness, y: rect.minY,
					width: available - firstSize, height: rect.height))
			}
		}

		walk(root, rect: CGRect(origin: .zero, size: size))
		return PaneLayout(panes: panes, dividers: dividers)
	}

	func ratioBinding(for nodeId: UUID) -> Binding<CGFloat> {
		Binding<CGFloat>(
			get: { [weak self] in
				guard let self else { return 0.5 }
				return self.findNodeById(nodeId, in: self.root)?.splitRatio ?? 0.5
			},
			set: { [weak self] newValue in
				guard let self else { return }
				if let node = self.findNodeById(nodeId, in: self.root) {
					node.splitRatio = newValue
					self.objectWillChange.send()
				}
			}
		)
	}
}

// MARK: - Command Area View (Flat Layout)

struct CommandArea: View {
	let project: Project
	@ObservedObject var state: CommandAreaState
	let areaWidth: CGFloat
	@State private var areaHeight: CGFloat = 1

	var body: some View {
		let size = CGSize(width: areaWidth, height: areaHeight)
		let layout = state.calculateLayout(in: size)
		ZStack(alignment: .topLeading) {
			// Height reader — width is passed from parent, height is read here
			Color.clear
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(GeometryReader { geo in
					Color.clear
						.onAppear { areaHeight = geo.size.height }
						.onChange(of: geo.size.height) { _, h in areaHeight = h }
				})

			// Terminal panes — flat ForEach ensures views are never destroyed on split
			ForEach(layout.panes) { pane in
				GhosttyTerminalView(project: project, paneId: pane.id.uuidString, paneIndex: pane.paneIndex)
					.frame(width: max(1, pane.rect.width), height: max(1, pane.rect.height))
					.offset(x: pane.rect.minX, y: pane.rect.minY)
			}
			// Dividers — rendered on top for hit testing
			ForEach(layout.dividers) { divider in
				PaneDivider(
					direction: divider.direction,
					availableSize: divider.availableSize,
					ratio: state.ratioBinding(for: divider.id)
				)
				.frame(width: divider.rect.width, height: divider.rect.height)
				.offset(x: divider.rect.minX, y: divider.rect.minY)
			}
		}
		.frame(width: areaWidth)
		.clipped()
		.background(Theme.bg)
	}
}

// MARK: - Pane Divider

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
