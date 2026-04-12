import SwiftUI

enum SplitDirection: String, Codable {
	case horizontal, vertical
}

enum PaneDropPosition {
	case left, right, top, bottom
}

class PaneNode: ObservableObject, Identifiable, Codable {
	let id: UUID
	var paneId: UUID?
	var paneIndex: Int?
	@Published var children: [PaneNode]?
	@Published var splitDirection: SplitDirection?
	@Published var splitRatio: CGFloat = 0.5

	init(id: UUID = UUID(), paneId: UUID? = UUID(), paneIndex: Int? = 0) {
		self.id = id
		self.paneId = paneId
		self.paneIndex = paneIndex
	}

	var isLeaf: Bool { children == nil && paneId != nil }

	// MARK: - Codable

	enum CodingKeys: String, CodingKey {
		case id, paneId, paneIndex, children, splitDirection, splitRatio
	}

	required init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(UUID.self, forKey: .id)
		let decodedPaneId = try c.decodeIfPresent(UUID.self, forKey: .paneId)
		paneIndex = try c.decodeIfPresent(Int.self, forKey: .paneIndex)
		children = try c.decodeIfPresent([PaneNode].self, forKey: .children)
		splitDirection = try c.decodeIfPresent(SplitDirection.self, forKey: .splitDirection)
		splitRatio = try c.decode(CGFloat.self, forKey: .splitRatio)

		// Backward compatibility for persisted layouts created before paneId existed.
		if children == nil {
			paneId = decodedPaneId ?? UUID()
			if paneIndex == nil {
				paneIndex = 0
			}
		} else {
			paneId = decodedPaneId
		}
	}

	func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(id, forKey: .id)
		try c.encodeIfPresent(paneId, forKey: .paneId)
		try c.encodeIfPresent(paneIndex, forKey: .paneIndex)
		try c.encodeIfPresent(children, forKey: .children)
		try c.encodeIfPresent(splitDirection, forKey: .splitDirection)
		try c.encode(splitRatio, forKey: .splitRatio)
	}
}

// MARK: - Layout Calculation

struct PaneLayout {
	struct Pane: Identifiable {
		let id: UUID
		let paneId: UUID
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
	@Published var root = PaneNode(paneId: UUID(), paneIndex: 0)
	@Published var activePaneId: UUID?
	private var nextPaneIndex = 1
	/// Called when layout changes, so the manager can persist
	var onLayoutChanged: (() -> Void)?

	func splitActive(_ direction: SplitDirection) {
		let targetPaneId = activePaneId ?? firstLeaf(root)?.paneId
		guard let targetPaneId else { return }
		if splitNode(targetPaneId, direction: direction, in: root) {
			objectWillChange.send()
			onLayoutChanged?()
		}
	}

	private func splitNode(_ paneId: UUID, direction: SplitDirection, in node: PaneNode) -> Bool {
		if node.paneId == paneId && node.isLeaf {
			let existing = PaneNode(paneId: node.paneId, paneIndex: node.paneIndex)
			let newPane = PaneNode(paneId: UUID(), paneIndex: nextPaneIndex)
			nextPaneIndex += 1
			node.paneId = nil
			node.paneIndex = nil
			node.splitDirection = direction
			node.splitRatio = 0.5
			node.children = [existing, newPane]
			activePaneId = existing.paneId
			return true
		}
		for child in node.children ?? [] {
			if splitNode(paneId, direction: direction, in: child) {
				return true
			}
		}
		return false
	}

	func restoreNextPaneIndex() {
		nextPaneIndex = maxPaneIndex(root) + 1
	}

	private func maxPaneIndex(_ node: PaneNode) -> Int {
		var maxIdx = node.paneIndex ?? 0
		for child in node.children ?? [] {
			maxIdx = max(maxIdx, maxPaneIndex(child))
		}
		return maxIdx
	}

	func closeActivePane() {
		let targetPaneId = activePaneId ?? firstLeaf(root)?.paneId
		guard let targetPaneId else { return }
		removePane(targetPaneId)
	}

	func focusNextPane() {
		cycleActivePane(step: 1)
	}

	func focusPreviousPane() {
		cycleActivePane(step: -1)
	}

	func closePane(_ paneId: UUID) {
		activePaneId = paneId
		removePane(paneId)
	}

	func removePane(_ paneId: UUID) {
		if root.paneId == paneId && root.isLeaf {
			return
		}
		if removeNode(paneId, from: root, parent: nil) {
			objectWillChange.send()
			onLayoutChanged?()
		}
	}

	private func cycleActivePane(step: Int) {
		let paneIds = orderedPaneIds(in: root)
		guard !paneIds.isEmpty else { return }
		guard let current = activePaneId,
			  let currentIndex = paneIds.firstIndex(of: current) else {
			activePaneId = paneIds.first
			return
		}
		let nextIndex = (currentIndex + step + paneIds.count) % paneIds.count
		activePaneId = paneIds[nextIndex]
	}

	private func orderedPaneIds(in node: PaneNode) -> [UUID] {
		if let paneId = node.paneId, node.isLeaf {
			return [paneId]
		}
		return (node.children ?? []).flatMap { orderedPaneIds(in: $0) }
	}

	private func removeNode(_ paneId: UUID, from node: PaneNode, parent: PaneNode?) -> Bool {
		guard let children = node.children else { return false }
		for (index, child) in children.enumerated() {
			if child.paneId == paneId && child.isLeaf {
				let sibling = children[1 - index]
				node.paneId = sibling.paneId
				node.paneIndex = sibling.paneIndex
				node.children = sibling.children
				node.splitDirection = sibling.splitDirection
				node.splitRatio = sibling.splitRatio
				if sibling.children != nil {
					node.paneId = nil
					node.paneIndex = nil
				}
				if sibling.isLeaf {
					activePaneId = sibling.paneId
				}
				return true
			}
			if removeNode(paneId, from: child, parent: node) {
				return true
			}
		}
		return false
	}

	func movePane(_ sourcePaneId: UUID, relativeTo targetPaneId: UUID, position: PaneDropPosition) {
		guard sourcePaneId != targetPaneId else { return }
		guard let workingRoot = deepCopy(root),
			  hasLeaf(sourcePaneId, in: workingRoot),
			  hasLeaf(targetPaneId, in: workingRoot),
			  let source = detachPane(sourcePaneId, in: workingRoot),
			  insertPane(source, relativeTo: targetPaneId, position: position, in: workingRoot) else {
			return
		}
		guard leafCount(in: workingRoot) == leafCount(in: root) else { return }
		root = workingRoot
		activePaneId = source.paneId
		objectWillChange.send()
		onLayoutChanged?()
	}

	func findNode(_ paneId: String) -> PaneNode? {
		guard let uuid = UUID(uuidString: paneId) else { return nil }
		return findLeafByPaneId(uuid, in: root)
	}

	func findLeafByPaneId(_ paneId: UUID, in node: PaneNode) -> PaneNode? {
		if node.paneId == paneId && node.isLeaf { return node }
		for child in node.children ?? [] {
			if let found = findLeafByPaneId(paneId, in: child) { return found }
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

	private func hasLeaf(_ paneId: UUID, in node: PaneNode) -> Bool {
		if node.paneId == paneId && node.isLeaf { return true }
		for child in node.children ?? [] {
			if hasLeaf(paneId, in: child) { return true }
		}
		return false
	}

	private struct LeafLocation {
		let node: PaneNode
		let parent: PaneNode
		let index: Int
	}

	private func detachPane(_ paneId: UUID, in root: PaneNode) -> PaneNode? {
		if root.paneId == paneId && root.isLeaf {
			return nil
		}
		return detachPane(paneId, from: root)
	}

	private func detachPane(_ paneId: UUID, from node: PaneNode) -> PaneNode? {
		guard let children = node.children else { return nil }
		for (index, child) in children.enumerated() {
			if child.paneId == paneId && child.isLeaf {
				let sibling = children[1 - index]
				let removed = child
				node.paneId = sibling.paneId
				node.paneIndex = sibling.paneIndex
				node.children = sibling.children
				node.splitDirection = sibling.splitDirection
				node.splitRatio = sibling.splitRatio
				if sibling.children != nil {
					node.paneId = nil
					node.paneIndex = nil
				}
				return removed
			}
			if let removed = detachPane(paneId, from: child) {
				return removed
			}
		}
		return nil
	}

	private func findLeafLocation(_ paneId: UUID, in node: PaneNode) -> LeafLocation? {
		guard let children = node.children else { return nil }
		for (index, child) in children.enumerated() {
			if child.paneId == paneId && child.isLeaf {
				return LeafLocation(node: child, parent: node, index: index)
			}
			if let found = findLeafLocation(paneId, in: child) {
				return found
			}
		}
		return nil
	}

	private func insertPane(_ pane: PaneNode, relativeTo targetPaneId: UUID, position: PaneDropPosition, in root: PaneNode) -> Bool {
		if root.paneId == targetPaneId && root.isLeaf {
			let targetCopy = PaneNode(paneId: root.paneId, paneIndex: root.paneIndex)
			root.paneId = nil
			root.paneIndex = nil
			root.splitDirection = splitDirection(for: position)
			root.splitRatio = 0.5
			root.children = orderedChildren(target: targetCopy, inserted: pane, position: position)
			return true
		}

		guard let target = findLeafLocation(targetPaneId, in: root) else { return false }
		let container = PaneNode(paneId: nil, paneIndex: nil)
		container.splitDirection = splitDirection(for: position)
		container.splitRatio = 0.5
		container.children = orderedChildren(target: target.node, inserted: pane, position: position)
		target.parent.children?[target.index] = container
		return true
	}

	private func splitDirection(for position: PaneDropPosition) -> SplitDirection {
		switch position {
		case .left, .right:
			return .horizontal
		case .top, .bottom:
			return .vertical
		}
	}

	private func orderedChildren(target: PaneNode, inserted: PaneNode, position: PaneDropPosition) -> [PaneNode] {
		switch position {
		case .left, .top:
			return [inserted, target]
		case .right, .bottom:
			return [target, inserted]
		}
	}

	private func deepCopy(_ node: PaneNode) -> PaneNode? {
		guard let data = try? JSONEncoder().encode(node) else { return nil }
		return try? JSONDecoder().decode(PaneNode.self, from: data)
	}

	private func leafCount(in node: PaneNode) -> Int {
		guard let children = node.children else { return 1 }
		return children.reduce(0) { $0 + leafCount(in: $1) }
	}

	// MARK: - Flat Layout Calculation

	func calculateLayout(in size: CGSize) -> PaneLayout {
		var panes: [PaneLayout.Pane] = []
		var dividers: [PaneLayout.DividerItem] = []
		let dividerThickness: CGFloat = 1

		func walk(_ node: PaneNode, rect: CGRect) {
			if node.isLeaf {
				guard let paneId = node.paneId, let paneIndex = node.paneIndex else { return }
				panes.append(.init(id: paneId, paneId: paneId, paneIndex: paneIndex, rect: rect))
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
				return self.findLayoutNode(nodeId, in: self.root)?.splitRatio ?? 0.5
			},
			set: { [weak self] newValue in
				guard let self else { return }
				if let node = self.findLayoutNode(nodeId, in: self.root) {
					node.splitRatio = newValue
					self.objectWillChange.send()
				}
			}
		)
	}

	private func findLayoutNode(_ nodeId: UUID, in node: PaneNode) -> PaneNode? {
		if node.id == nodeId { return node }
		for child in node.children ?? [] {
			if let found = findLayoutNode(nodeId, in: child) { return found }
		}
		return nil
	}
}

// MARK: - Command Area View (Flat Layout)

struct CommandArea: View {
	let project: Project
	@ObservedObject var state: CommandAreaState
	@State private var dragState: PaneDragState?
	@State private var connectionLoadingPanes: Set<UUID> = []
	@State private var connectionStatusMessages: [UUID: String] = [:]
	@State private var disconnectedPanes: Set<UUID> = []
	private let paneHeaderHeight: CGFloat = 24

	private struct PaneDragState {
		let sourcePaneId: UUID
		var currentLocation: CGPoint
	}

	private struct PaneDropTarget {
		let paneId: UUID
		let position: PaneDropPosition
	}

	var body: some View {
		GeometryReader { geo in
			let layout = state.calculateLayout(in: geo.size)
			ZStack(alignment: .topLeading) {
				// Terminal panes — flat ForEach ensures views are never destroyed on split
				ForEach(layout.panes) { pane in
					let isDraggingSource = dragState?.sourcePaneId == pane.paneId
					VStack(spacing: 0) {
						PaneChrome(
							title: "Pane \(pane.paneIndex + 1)",
							isActive: state.activePaneId == pane.paneId,
							isDragging: isDraggingSource,
							onActivate: { state.activePaneId = pane.paneId },
							onClose: { state.closePane(pane.paneId) },
							onDragChanged: { value in
								state.activePaneId = pane.paneId
								dragState = PaneDragState(
									sourcePaneId: pane.paneId,
									currentLocation: CGPoint(
										x: pane.rect.minX + value.location.x,
										y: pane.rect.minY + value.location.y
									)
								)
							},
							onDragEnded: { value in
								let dropPoint = CGPoint(
									x: pane.rect.minX + value.location.x,
									y: pane.rect.minY + value.location.y
								)
								let target = dropTarget(for: dropPoint, in: layout, excluding: pane.paneId)
								dragState = nil
								if let target {
									state.movePane(pane.paneId, relativeTo: target.paneId, position: target.position)
								}
							}
						)
						.frame(height: min(paneHeaderHeight, max(0, pane.rect.height)))

						XTermTerminalView(
								project: project,
								paneId: pane.paneId.uuidString,
								paneIndex: pane.paneIndex,
								viewWidth: max(1, pane.rect.width),
								viewHeight: max(1, pane.rect.height - paneHeaderHeight)
							)
							.frame(
								width: max(1, pane.rect.width),
								height: max(1, pane.rect.height - paneHeaderHeight)
							)
							.opacity(isDraggingSource ? 0.38 : 1)
							.overlay(alignment: .top) {
								if connectionLoadingPanes.contains(pane.paneId) {
									TerminalLoadingOverlay(
										statusMessage: connectionStatusMessages[pane.paneId]
									)
								}
							}
							.overlay {
								if disconnectedPanes.contains(pane.paneId) {
									TerminalDisconnectedOverlay(projectId: project.id)
								}
							}
					}
						.overlay {
							if let dropTarget = dropTarget(in: layout), dropTarget.paneId == pane.paneId {
								PaneDropOverlay(position: dropTarget.position)
									.padding(3)
									.allowsHitTesting(false)
							}
							if isDraggingSource {
								PaneDragOverlay()
									.padding(3)
									.allowsHitTesting(false)
							}
						}
						.frame(width: max(1, pane.rect.width), height: max(1, pane.rect.height), alignment: .topLeading)
						.scaleEffect(isDraggingSource ? 0.985 : 1)
						.shadow(
							color: .black.opacity(isDraggingSource ? 0.28 : 0),
							radius: isDraggingSource ? 10 : 0,
							y: isDraggingSource ? 3 : 0
						)
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
		.onReceive(NotificationCenter.default.publisher(for: .belveTerminalConnectionState)) { notif in
			guard let projectId = notif.userInfo?["projectId"] as? UUID,
				  projectId == project.id,
				  let paneIdString = notif.userInfo?["paneId"] as? String,
				  let paneId = UUID(uuidString: paneIdString),
				  let isLoading = notif.userInfo?["isLoading"] as? Bool else { return }
			if isLoading {
				disconnectedPanes.remove(paneId)
				connectionLoadingPanes.insert(paneId)
			} else {
				connectionLoadingPanes.remove(paneId)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveTerminalConnectionStatus)) { notif in
			guard let projectId = notif.userInfo?["projectId"] as? UUID,
				  projectId == project.id,
				  let paneIdString = notif.userInfo?["paneId"] as? String,
				  let paneId = UUID(uuidString: paneIdString) else { return }
			if let message = notif.userInfo?["message"] as? String {
				connectionStatusMessages[paneId] = message
			} else {
				connectionStatusMessages.removeValue(forKey: paneId)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .belveTerminalDisconnected)) { notif in
			guard let projectId = notif.userInfo?["projectId"] as? UUID,
				  projectId == project.id,
				  let paneIdString = notif.userInfo?["paneId"] as? String,
				  let paneId = UUID(uuidString: paneIdString),
				  let isDisconnected = notif.userInfo?["isDisconnected"] as? Bool else { return }
			if isDisconnected {
				connectionLoadingPanes.remove(paneId)
				disconnectedPanes.insert(paneId)
			} else {
				disconnectedPanes.remove(paneId)
			}
		}
	}

	private func dropTarget(in layout: PaneLayout) -> PaneDropTarget? {
		guard let dragState else { return nil }
		return dropTarget(for: dragState.currentLocation, in: layout, excluding: dragState.sourcePaneId)
	}

	private func dropTarget(for point: CGPoint, in layout: PaneLayout, excluding sourcePaneId: UUID) -> PaneDropTarget? {
		guard let pane = layout.panes.first(where: {
			$0.paneId != sourcePaneId && $0.rect.contains(point)
		}) else { return nil }
		return PaneDropTarget(
			paneId: pane.paneId,
			position: dropPosition(for: point, in: pane.rect)
		)
	}

	private func dropPosition(for point: CGPoint, in rect: CGRect) -> PaneDropPosition {
		let xRatio = (point.x - rect.minX) / max(rect.width, 1)
		let yRatio = (point.y - rect.minY) / max(rect.height, 1)

		let verticalBand = min(0.36, max(0.22, 72 / max(rect.height, 1)))
		let horizontalBand = min(0.28, max(0.18, 56 / max(rect.width, 1)))

		if yRatio <= verticalBand { return .top }
		if yRatio >= 1 - verticalBand { return .bottom }
		if xRatio <= horizontalBand { return .left }
		if xRatio >= 1 - horizontalBand { return .right }

		let leftDistance = xRatio
		let rightDistance = 1 - xRatio
		let topDistance = yRatio
		let bottomDistance = 1 - yRatio
		let minDistance = min(leftDistance, rightDistance, topDistance, bottomDistance)
		if minDistance == topDistance { return .top }
		if minDistance == bottomDistance { return .bottom }
		if minDistance == leftDistance { return .left }
		return .right
	}
}

private struct TerminalLoadingOverlay: View {
	var statusMessage: String?

	var body: some View {
		VStack(spacing: 0) {
			LoadingTrack(trackHeight: 2, widthFactor: 0.28, minimumWidth: 120)
				.frame(height: 2)
				.frame(maxWidth: .infinity, alignment: .leading)

			if let statusMessage {
				HStack(spacing: 6) {
					ProgressView()
						.controlSize(.small)
						.scaleEffect(0.7)
					Text(statusMessage)
						.font(.system(size: 11))
						.foregroundStyle(Theme.textSecondary)
				}
				.padding(.top, 12)
				.padding(.horizontal, 12)
				.frame(maxWidth: .infinity, alignment: .leading)
				.transition(.opacity)
				.animation(.easeOut(duration: 0.2), value: statusMessage)
			}
		}
		.allowsHitTesting(false)
	}
}

private struct TerminalDisconnectedOverlay: View {
	let projectId: UUID

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("SSH disconnected")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(Theme.textPrimary)

			Text("Reconnect to resume this terminal.")
				.font(.system(size: 11))
				.foregroundStyle(Theme.textSecondary)

			Button("Reconnect") {
				NotificationCenter.default.post(
					name: .belveReloadProject,
					object: nil,
					userInfo: ["projectId": projectId]
				)
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(
				RoundedRectangle(cornerRadius: 8)
					.fill(Theme.surface)
			)
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(Theme.borderSubtle, lineWidth: 1)
			)
		}
		.padding(16)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(
			LinearGradient(
				colors: [
					Theme.bg.opacity(0.84),
					Theme.bg.opacity(0.7)
				],
				startPoint: .top,
				endPoint: .bottom
			)
		)
	}
}

private struct PaneChrome: View {
	let title: String
	let isActive: Bool
	let isDragging: Bool
	let onActivate: () -> Void
	let onClose: () -> Void
	let onDragChanged: (DragGesture.Value) -> Void
	let onDragEnded: (DragGesture.Value) -> Void
	@State private var isHovering = false
	@State private var isHoveringClose = false

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				HStack(spacing: 3) {
					ForEach(0..<3, id: \.self) { _ in
						Circle()
							.fill(Theme.textTertiary)
							.frame(width: 3, height: 3)
					}
				}
				.padding(.leading, 8)

				Text(title)
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(Theme.textSecondary)

				Spacer()

				Button(action: onClose) {
					Image(systemName: "xmark")
						.font(.system(size: 9, weight: .bold))
						.foregroundStyle(isHoveringClose ? Theme.textPrimary : Theme.textTertiary)
						.frame(width: 18, height: 18)
				}
				.buttonStyle(.plain)
				.onHover { isHoveringClose = $0 }
				.padding(.trailing, 6)
			}
			.frame(height: 24)
			.background(chromeBackground)
			.contentShape(Rectangle())
			.onTapGesture(perform: onActivate)
			.gesture(
				DragGesture(minimumDistance: 3, coordinateSpace: .local)
					.onChanged(onDragChanged)
					.onEnded(onDragEnded)
			)

			Spacer()
		}
		.onHover { isHovering = $0 }
	}

	@ViewBuilder
	private var chromeBackground: some View {
		if isDragging {
			Theme.accent.opacity(0.22)
		} else if isActive {
			Theme.surfaceActive
		} else if isHovering {
			Theme.surfaceHover
		} else {
			Color.black.opacity(0.12)
		}
	}
}

private struct PaneDragOverlay: View {
	var body: some View {
		RoundedRectangle(cornerRadius: 8)
			.fill(Color.white.opacity(0.04))
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
			)
	}
}

private struct PaneDropOverlay: View {
	let position: PaneDropPosition

	var body: some View {
		GeometryReader { geo in
			ZStack(alignment: alignment) {
				RoundedRectangle(cornerRadius: 6)
					.fill(Theme.accent.opacity(0.08))

				highlight(in: geo.size)
			}
		}
	}

	private var alignment: Alignment {
		switch position {
		case .left:
			return .leading
		case .right:
			return .trailing
		case .top:
			return .top
		case .bottom:
			return .bottom
		}
	}

	@ViewBuilder
	private func highlight(in size: CGSize) -> some View {
		let thickness = max(56, min(size.width, size.height) * 0.33)
		switch position {
		case .left:
			RoundedRectangle(cornerRadius: 6)
				.fill(Theme.accent.opacity(0.22))
				.frame(width: min(thickness, size.width))
		case .right:
			RoundedRectangle(cornerRadius: 6)
				.fill(Theme.accent.opacity(0.22))
				.frame(width: min(thickness, size.width))
		case .top:
			RoundedRectangle(cornerRadius: 6)
				.fill(Theme.accent.opacity(0.22))
				.frame(height: min(thickness, size.height))
		case .bottom:
			RoundedRectangle(cornerRadius: 6)
				.fill(Theme.accent.opacity(0.22))
				.frame(height: min(thickness, size.height))
		}
	}
}

// MARK: - Pane Divider

struct PaneDivider: View {
	let direction: SplitDirection
	let availableSize: CGFloat
	@Binding var ratio: CGFloat
	@State private var isDragging = false
	@State private var ratioAtDragStart: CGFloat = 0

	private var resizeCursor: NSCursor {
		direction == .vertical ? .resizeUpDown : .resizeLeftRight
	}

	var body: some View {
		let isVertical = direction == .vertical
		Rectangle()
			.fill(isDragging ? Theme.border : Theme.borderSubtle)
			.frame(width: isVertical ? nil : DividerMetrics.lineWidth, height: isVertical ? DividerMetrics.lineWidth : nil)
			.contentShape(Rectangle())
			.frame(width: isVertical ? nil : DividerMetrics.paneHitWidth, height: isVertical ? DividerMetrics.paneHitWidth : nil)
			.dividerCursor(resizeCursor)
			.onContinuousHover { phase in
				switch phase {
				case .active:
					resizeCursor.set()
				case .ended:
					break
				}
			}
			.zIndex(1000)
			.gesture(
				DragGesture(minimumDistance: 1, coordinateSpace: .global)
					.onChanged { value in
						if !isDragging {
							isDragging = true
							ratioAtDragStart = ratio
							resizeCursor.push()
						}
						let translation = isVertical ? value.translation.height : value.translation.width
						let newRatio = ratioAtDragStart + translation / availableSize
						ratio = max(0.15, min(0.85, newRatio))
					}
					.onEnded { _ in
						NSCursor.pop()
						isDragging = false
					}
			)
	}
}
