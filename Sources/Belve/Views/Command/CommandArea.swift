import SwiftUI

enum SplitDirection: String, Codable {
	case horizontal, vertical
}

class PaneNode: ObservableObject, Identifiable, Codable {
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

	// MARK: - Codable

	enum CodingKeys: String, CodingKey {
		case id, paneIndex, children, splitDirection, splitRatio
	}

	required init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(UUID.self, forKey: .id)
		paneIndex = try c.decode(Int.self, forKey: .paneIndex)
		children = try c.decodeIfPresent([PaneNode].self, forKey: .children)
		splitDirection = try c.decodeIfPresent(SplitDirection.self, forKey: .splitDirection)
		splitRatio = try c.decode(CGFloat.self, forKey: .splitRatio)
	}

	func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(id, forKey: .id)
		try c.encode(paneIndex, forKey: .paneIndex)
		try c.encodeIfPresent(children, forKey: .children)
		try c.encodeIfPresent(splitDirection, forKey: .splitDirection)
		try c.encode(splitRatio, forKey: .splitRatio)
	}
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

// MARK: - Per-Project State Manager

class CommandAreaStateManager: ObservableObject {
	private var states: [UUID: CommandAreaState] = [:]

	private static var saveURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("pane-layouts.json")
	}

	init() {
		load()
	}

	func state(for projectId: UUID) -> CommandAreaState {
		if let existing = states[projectId] {
			return existing
		}
		let state = CommandAreaState()
		state.onLayoutChanged = { [weak self] in self?.save() }
		states[projectId] = state
		return state
	}

	func save() {
		let data: [String: PaneNode] = states.reduce(into: [:]) { result, pair in
			result[pair.key.uuidString] = pair.value.root
		}
		if let encoded = try? JSONEncoder().encode(data) {
			try? encoded.write(to: Self.saveURL)
		}
	}

	private func load() {
		guard let data = try? Data(contentsOf: Self.saveURL),
			  let decoded = try? JSONDecoder().decode([String: PaneNode].self, from: data) else { return }
		for (key, root) in decoded {
			if let uuid = UUID(uuidString: key) {
				let state = CommandAreaState()
				state.root = root
				state.restoreNextPaneIndex()
				state.onLayoutChanged = { [weak self] in self?.save() }
				states[uuid] = state
			}
		}
		NSLog("[Belve] Restored pane layouts for \(states.count) projects")
	}
}

// MARK: - Command Area State

class CommandAreaState: ObservableObject {
	@Published var root = PaneNode(paneIndex: 0)
	@Published var activePaneId: UUID?
	private var nextPaneIndex = 1
	/// Called when layout changes, so the manager can persist
	var onLayoutChanged: (() -> Void)?

	func splitActive(_ direction: SplitDirection) {
		let targetId = activePaneId ?? firstLeaf(root)?.id
		guard let targetId else { return }
		if splitNode(targetId, direction: direction, in: root) {
			objectWillChange.send()
			onLayoutChanged?()
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

	func restoreNextPaneIndex() {
		nextPaneIndex = maxPaneIndex(root) + 1
	}

	private func maxPaneIndex(_ node: PaneNode) -> Int {
		var maxIdx = node.paneIndex
		for child in node.children ?? [] {
			maxIdx = max(maxIdx, maxPaneIndex(child))
		}
		return maxIdx
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
			onLayoutChanged?()
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

	var body: some View {
		GeometryReader { geo in
			let layout = state.calculateLayout(in: geo.size)
			ZStack(alignment: .topLeading) {
				// Terminal panes — flat ForEach ensures views are never destroyed on split
				ForEach(layout.panes) { pane in
					XTermTerminalView(project: project, paneId: pane.id.uuidString, paneIndex: pane.paneIndex)
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
		}
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
