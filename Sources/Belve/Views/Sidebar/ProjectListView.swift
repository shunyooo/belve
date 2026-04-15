import SwiftUI

struct ProjectListView: View {
	let projects: [Project]
	@Binding var selectedProject: Project?
	@EnvironmentObject var notificationStore: NotificationStore
	var onAddProject: (() -> Void)?
	var onToggleSidebar: (() -> Void)?
	var onRenameProject: ((UUID, String) -> Void)?
	var onDeleteProject: ((UUID) -> Void)?
	var onMoveProject: ((IndexSet, Int) -> Void)?

	@State private var renamingProjectId: UUID?
	@State private var renameText = ""
	@State private var contextMenuProjectId: UUID?

	// Drag & drop state
	@State private var draggingProjectId: UUID?
	@State private var dropTargetIndex: Int?

	var body: some View {
		ZStack {
			VStack(alignment: .leading, spacing: 0) {
				Spacer().frame(height: Theme.titlebarHeight)
				ScrollView {
					VStack(spacing: 2) {
						ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
							if renamingProjectId == project.id {
								RenameField(text: $renameText) {
									if !renameText.isEmpty {
										onRenameProject?(project.id, renameText)
									}
									renamingProjectId = nil
								}
								.padding(.horizontal, 8)
							} else {
								// Drop indicator above this row
								if dropTargetIndex == index && draggingProjectId != project.id {
									dropIndicator()
								}

								ProjectRow(
									project: project,
									isSelected: selectedProject == project,
										agentState: notificationStore.agentStatus[project.id]
								)
								.opacity(draggingProjectId == project.id ? 0.4 : 1.0)
								.overlay(
									DragSourceView(
										projectId: project.id,
										onDragStarted: { draggingProjectId = project.id },
										onClick: { selectedProject = project },
										onRightClick: { _ in
											contextMenuProjectId = project.id
										}
									)
								)
								.overlay(alignment: .topTrailing) {
									if contextMenuProjectId == project.id {
										ProjectContextMenu(
											onRename: {
												renameText = project.name
												renamingProjectId = project.id
												contextMenuProjectId = nil
											},
											onDelete: {
												onDeleteProject?(project.id)
												contextMenuProjectId = nil
											}
										)
										.offset(x: 20, y: 30)
										.transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
									}
								}
								.zIndex(contextMenuProjectId == project.id ? 100 : 0)
								.onDrop(of: [.text], delegate: ProjectDropDelegate(
									targetIndex: index,
									projects: projects,
									draggingProjectId: $draggingProjectId,
									dropTargetIndex: $dropTargetIndex,
									onMoveProject: onMoveProject
								))
							}
						}

						// Drop indicator at the end
						if dropTargetIndex == projects.count {
							dropIndicator()
						}

						// Drop target for the empty area below the list
						Color.clear
							.frame(height: 20)
							.onDrop(of: [.text], delegate: ProjectDropDelegate(
								targetIndex: projects.count,
								projects: projects,
								draggingProjectId: $draggingProjectId,
								dropTargetIndex: $dropTargetIndex,
								onMoveProject: onMoveProject
							))
					}
					.padding(.horizontal, 8)
				}
			}
			.overlay(alignment: .topTrailing) {
				HStack(spacing: 4) {
					SidebarIconButton(icon: "plus", action: { onAddProject?() })
					SidebarIconButton(icon: "sidebar.left", action: { onToggleSidebar?() })
				}
				.padding(.trailing, 6)
				.padding(.top, 4)
			}

			// Dismiss context menu on tap outside
			if contextMenuProjectId != nil {
				Color.clear
					.contentShape(Rectangle())
					.onTapGesture { contextMenuProjectId = nil }
					.onExitCommand { contextMenuProjectId = nil }
			}
		}
		.animation(.easeOut(duration: 0.12), value: contextMenuProjectId != nil)
	}

	private func dropIndicator() -> some View {
		HStack(spacing: 4) {
			Circle().fill(Theme.accent).frame(width: 5, height: 5)
			Theme.accent.frame(height: 2)
			Circle().fill(Theme.accent).frame(width: 5, height: 5)
		}
		.padding(.horizontal, 12)
		.transition(.opacity)
	}
}

// MARK: - Drop Delegate

struct ProjectDropDelegate: DropDelegate {
	let targetIndex: Int
	let projects: [Project]
	@Binding var draggingProjectId: UUID?
	@Binding var dropTargetIndex: Int?
	var onMoveProject: ((IndexSet, Int) -> Void)?

	func dropEntered(info: DropInfo) {
		withAnimation(.easeOut(duration: 0.15)) {
			dropTargetIndex = targetIndex
		}
	}

	func dropUpdated(info: DropInfo) -> DropProposal? {
		DropProposal(operation: .move)
	}

	func performDrop(info: DropInfo) -> Bool {
		guard let dragId = draggingProjectId,
			  let sourceIndex = projects.firstIndex(where: { $0.id == dragId }) else {
			reset()
			return false
		}
		let dest = targetIndex > sourceIndex ? targetIndex : targetIndex
		if sourceIndex != dest && sourceIndex + 1 != dest {
			onMoveProject?(IndexSet(integer: sourceIndex), dest)
		}
		reset()
		return true
	}

	func dropExited(info: DropInfo) {
		// Only clear if we're leaving this specific target
	}

	func validateDrop(info: DropInfo) -> Bool {
		draggingProjectId != nil
	}

	private func reset() {
		withAnimation(.easeOut(duration: 0.15)) {
			draggingProjectId = nil
			dropTargetIndex = nil
		}
	}
}

// MARK: - Custom Context Menu

struct ProjectContextMenu: View {
	let onRename: () -> Void
	let onDelete: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			ContextMenuItem(label: "Rename", icon: "pencil", action: onRename)
			ContextMenuDivider()
			ContextMenuItem(label: "Delete", icon: "trash", isDestructive: true, action: onDelete)
		}
		.padding(.vertical, 4)
		.frame(width: 160)
		.background(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.fill(.ultraThinMaterial)
				.environment(\.colorScheme, .dark)
		)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.strokeBorder(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.4), radius: 12, y: 4)
	}
}

struct ContextMenuItem: View {
	let label: String
	let icon: String
	var isDestructive: Bool = false
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 8) {
				Image(systemName: icon)
					.font(.system(size: 11))
					.frame(width: 16)
				Text(label)
					.font(.system(size: 12))
				Spacer()
			}
			.foregroundStyle(isDestructive ? Theme.red : (isHovering ? Theme.textPrimary : Theme.textSecondary))
			.padding(.horizontal, 10)
			.padding(.vertical, 5)
			.background(
				RoundedRectangle(cornerRadius: 4)
					.fill(isHovering ? Theme.surfaceHover : Color.clear)
			)
			.padding(.horizontal, 4)
		}
		.buttonStyle(.plain)
		.onHover { hovering in
			isHovering = hovering
		}
	}
}

struct ContextMenuDivider: View {
	var body: some View {
		Theme.border
			.frame(height: 1)
			.padding(.horizontal, 8)
			.padding(.vertical, 2)
	}
}

// MARK: - Drag Source (NSView-based, doesn't block clicks)

struct DragSourceView: NSViewRepresentable {
	let projectId: UUID
	let onDragStarted: () -> Void
	let onClick: () -> Void
	var onRightClick: ((CGPoint) -> Void)?

	func makeNSView(context: Context) -> DragSourceNSView {
		let view = DragSourceNSView()
		view.projectId = projectId
		view.onDragStarted = onDragStarted
		view.onClick = onClick
		view.onRightClick = onRightClick
		return view
	}

	func updateNSView(_ nsView: DragSourceNSView, context: Context) {
		nsView.projectId = projectId
		nsView.onDragStarted = onDragStarted
		nsView.onClick = onClick
		nsView.onRightClick = onRightClick
	}

	class DragSourceNSView: NSView {
		var projectId: UUID?
		var onDragStarted: (() -> Void)?
		var onClick: (() -> Void)?
		var onRightClick: ((CGPoint) -> Void)?
		private var mouseDownLocation: NSPoint?
		private var didDrag = false
		private let dragThreshold: CGFloat = 4

		override func mouseDown(with event: NSEvent) {
			mouseDownLocation = event.locationInWindow
			didDrag = false
		}

		override func mouseDragged(with event: NSEvent) {
			guard let startLocation = mouseDownLocation, let projectId, !didDrag else { return }
			let current = event.locationInWindow
			let dx = current.x - startLocation.x
			let dy = current.y - startLocation.y
			guard sqrt(dx * dx + dy * dy) > dragThreshold else { return }

			didDrag = true
			onDragStarted?()

			let item = NSDraggingItem(pasteboardWriter: projectId.uuidString as NSString)
			item.setDraggingFrame(bounds, contents: snapshot())
			beginDraggingSession(with: [item], event: event, source: self)
		}

		override func mouseUp(with event: NSEvent) {
			if !didDrag {
				onClick?()
			}
			mouseDownLocation = nil
			didDrag = false
		}

		override func rightMouseDown(with event: NSEvent) {
			guard let contentView = window?.contentView else { return }
			let windowPoint = contentView.convert(event.locationInWindow, from: nil)
			let swiftUIPoint = CGPoint(x: windowPoint.x, y: contentView.bounds.height - windowPoint.y)
			onRightClick?(swiftUIPoint)
		}

		private func snapshot() -> NSImage {
			let image = NSImage(size: bounds.size)
			image.lockFocus()
			if let ctx = NSGraphicsContext.current?.cgContext {
				layer?.render(in: ctx)
			}
			image.unlockFocus()
			return image
		}
	}
}

extension DragSourceView.DragSourceNSView: NSDraggingSource {
	func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
		.move
	}
}

// MARK: - Rename Field

struct RenameField: View {
	@Binding var text: String
	let onCommit: () -> Void
	@FocusState private var isFocused: Bool

	var body: some View {
		TextField("Project name", text: $text)
			.textFieldStyle(.plain)
			.font(Theme.fontBody)
			.foregroundStyle(Theme.textPrimary)
			.padding(.horizontal, 10)
			.padding(.vertical, 7)
			.background(
				RoundedRectangle(cornerRadius: Theme.radiusSm)
					.fill(Theme.surfaceActive)
			)
			.focused($isFocused)
			.onAppear { isFocused = true }
			.onSubmit { onCommit() }
			.onExitCommand { onCommit() }
	}
}

// MARK: - Sidebar Icon Button

struct SidebarIconButton: View {
	let icon: String
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: icon)
				.font(.system(size: 14, weight: .medium))
				.foregroundStyle(isHovering ? Theme.textPrimary : Theme.textTertiary)
				.frame(width: 28, height: 28)
		}
		.buttonStyle(.plain)
		.onHover { hovering in
			isHovering = hovering
		}
	}
}

// MARK: - Project Row

struct ProjectRow: View {
	let project: Project
	let isSelected: Bool
	var agentState: AgentState?
	@State private var isHovering = false

	private var subtitle: String {
		let label = project.provider.displayLabel
		if !label.isEmpty {
			return label
		}
		if let path = project.path {
			return "~/\((path as NSString).lastPathComponent)"
		}
		return ""
	}

	var body: some View {
		HStack(spacing: 10) {

			VStack(alignment: .leading, spacing: 1) {
				Text(project.name)
					.font(Theme.fontBody)
					.foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
					.lineLimit(1)

				Text(subtitle)
					.font(.system(size: 10))
					.foregroundStyle(Theme.textTertiary)
					.lineLimit(1)
			}

			Spacer()
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
		.background(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.fill(isSelected ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
		)
		.overlay(
			HStack {
				if isSelected {
					RoundedRectangle(cornerRadius: 1)
						.fill(Theme.accent)
						.frame(width: 2, height: 16)
						.transition(.opacity.combined(with: .scale))
				}
				Spacer()
			}
		)
		.contentShape(Rectangle())
		.onHover { hovering in
			isHovering = hovering
		}
	}
}
