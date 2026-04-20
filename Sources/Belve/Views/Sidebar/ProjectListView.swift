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
	var onFocusPane: ((UUID, String) -> Void)?
	@ObservedObject var activeCommandState: CommandAreaState

	@State private var renamingProjectId: UUID?
	@State private var renameText = ""
	@State private var contextMenuProjectId: UUID?
	@State private var draggingProjectId: UUID?
	@State private var dropTargetIndex: Int?

	@Namespace private var selectionNamespace

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
								if dropTargetIndex == index && draggingProjectId != project.id {
									dropIndicator()
								}

								projectSection(project: project, index: index)
							}
						}

						if dropTargetIndex == projects.count {
							dropIndicator()
						}

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
		}
		.onTapGesture {
			if contextMenuProjectId != nil {
				contextMenuProjectId = nil
			}
		}
		.animation(.easeOut(duration: 0.12), value: contextMenuProjectId != nil)
		.animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.18), value: selectedProject)
		.onReceive(NotificationCenter.default.publisher(for: .belvePaneClosed)) { notif in
			if let paneId = notif.userInfo?["paneId"] as? String {
				notificationStore.archiveSessionsForPane(paneId)
			}
		}
	}

	// MARK: - Project Section (project row + nested sessions)

	private func projectSection(project: Project, index: Int) -> some View {
		VStack(spacing: 0) {
			ProjectRow(
				project: project,
				isSelected: selectedProject == project,
				agentState: notificationStore.agentStatus[project.id],
				selectionNamespace: selectionNamespace
			)
			.opacity(draggingProjectId == project.id ? 0.4 : 1.0)
			.overlay(
				DragSourceView(
					projectId: project.id,
					onDragStarted: { draggingProjectId = project.id },
					onClick: { selectedProject = project },
					onRightClick: { _ in contextMenuProjectId = project.id }
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

			// Nested agent sessions for this project
			let sessions = sessionsForProject(project.id)
			if !sessions.isEmpty {
				VStack(spacing: 1) {
					ForEach(sessions) { session in
						SessionRow(
							session: session,
							isFocused: session.paneId.flatMap { UUID(uuidString: $0) } == activeCommandState.activePaneId
								&& selectedProject == project
						)
						.onTapGesture {
							selectedProject = project
							if let paneId = session.paneId {
								onFocusPane?(project.id, paneId)
							}
						}
					}
				}
				.padding(.leading, 16)
				.padding(.trailing, 4)
				.padding(.bottom, 4)
			}
		}
	}

	private func sessionsForProject(_ projectId: UUID) -> [AgentSession] {
		notificationStore.sessions
			.filter { $0.projectId == projectId && !$0.isArchived }
			.sorted { $0.updatedAt > $1.updatedAt }
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

// MARK: - Session Row (nested under project)

private struct SessionRow: View {
	let session: AgentSession
	var isFocused: Bool = false
	@State private var isHovering = false

	private var statusColor: Color {
		switch session.status {
		case .running: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed, .sessionEnd: return Theme.green
		case .sessionStart: return Theme.accent
		case .idle: return Theme.textTertiary
		}
	}

	private var isActive: Bool {
		session.status == .running || session.status == .waiting || session.status == .sessionStart
	}

	var body: some View {
		HStack(alignment: .top, spacing: 6) {
			VStack {
				Spacer().frame(height: 3)
				if isActive {
					PulsingDot(color: statusColor)
				} else {
					Circle()
						.fill(statusColor.opacity(session.status == .completed ? 1 : 0.3))
						.frame(width: 6, height: 6)
						.frame(width: 10, height: 10)
				}
			}

			VStack(alignment: .leading, spacing: 2) {
				Text(session.lastUserPrompt ?? session.label ?? session.message)
					.font(.system(size: 11, weight: isActive ? .medium : .regular))
					.foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
					.lineLimit(2)

				if isActive || session.status == .completed {
					VStack(alignment: .leading, spacing: 1) {
						if let tool = session.currentTool {
							HStack(spacing: 3) {
								Image(systemName: "wrench.and.screwdriver")
									.font(.system(size: 8))
								Text(tool)
									.lineLimit(1)
							}
							.font(.system(size: 9))
							.foregroundStyle(Theme.accent)

							if let detail = session.lastAgentActivity, !detail.isEmpty {
								Text(detail)
									.font(.system(size: 9))
									.foregroundStyle(Theme.textTertiary)
									.lineLimit(3)
							}
						} else if session.status == .waiting {
							Text(session.message)
								.font(.system(size: 9))
								.foregroundStyle(Theme.yellow)
								.lineLimit(3)
						} else if session.status == .completed {
							if let activity = session.lastAgentActivity {
								Text(activity)
									.font(.system(size: 9))
									.foregroundStyle(Theme.textTertiary)
									.lineLimit(3)
							}
						} else {
							Text("Thinking...")
								.font(.system(size: 9))
								.foregroundStyle(Theme.textTertiary)
						}
					}
				}

				Text(session.updatedAt.relativeString)
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary.opacity(0.6))
			}

			Spacer(minLength: 0)
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 5)
		.background(
			RoundedRectangle(cornerRadius: 4)
				.fill(isFocused ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
		)
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}
}

// MARK: - Pulsing Dot

private struct PulsingDot: View {
	let color: Color
	@State private var isPulsing = false

	var body: some View {
		Circle()
			.fill(color)
			.frame(width: 6, height: 6)
			.overlay(
				Circle()
					.stroke(color.opacity(0.4), lineWidth: 1.5)
					.frame(width: 10, height: 10)
					.scaleEffect(isPulsing ? 1.3 : 1.0)
					.opacity(isPulsing ? 0 : 0.6)
			)
			.frame(width: 10, height: 10)
			.onAppear {
				withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
					isPulsing = true
				}
			}
	}
}

// MARK: - Date Extension

private extension Date {
	var relativeString: String {
		let interval = -timeIntervalSinceNow
		if interval < 60 { return "now" }
		if interval < 3600 { return "\(Int(interval / 60))m" }
		if interval < 86400 { return "\(Int(interval / 3600))h" }
		return "\(Int(interval / 86400))d"
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
		withAnimation(.easeOut(duration: 0.15)) { dropTargetIndex = targetIndex }
	}

	func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

	func performDrop(info: DropInfo) -> Bool {
		guard let dragId = draggingProjectId,
			  let sourceIndex = projects.firstIndex(where: { $0.id == dragId }) else {
			reset(); return false
		}
		let dest = targetIndex
		if sourceIndex != dest && sourceIndex + 1 != dest {
			onMoveProject?(IndexSet(integer: sourceIndex), dest)
		}
		reset(); return true
	}

	func dropExited(info: DropInfo) {}
	func validateDrop(info: DropInfo) -> Bool { draggingProjectId != nil }

	private func reset() {
		withAnimation(.easeOut(duration: 0.15)) {
			draggingProjectId = nil
			dropTargetIndex = nil
		}
	}
}

// MARK: - Context Menu

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
		.onHover { isHovering = $0 }
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

// MARK: - Drag Source

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
			if !didDrag { onClick?() }
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
			if let ctx = NSGraphicsContext.current?.cgContext { layer?.render(in: ctx) }
			image.unlockFocus()
			return image
		}
	}
}

extension DragSourceView.DragSourceNSView: NSDraggingSource {
	func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
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
			.background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.surfaceActive))
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
		.onHover { isHovering = $0 }
	}
}

// MARK: - Project Row

struct ProjectRow: View {
	let project: Project
	let isSelected: Bool
	var agentState: AgentState?
	var selectionNamespace: Namespace.ID?
	@EnvironmentObject var projectStore: ProjectStore
	@State private var isHovering = false

	private var subtitle: String {
		let label = project.provider.displayLabel
		if !label.isEmpty { return label }
		if let path = project.path {
			return "~/\((path as NSString).lastPathComponent)"
		}
		return ""
	}

	private var loadingStatus: String? {
		projectStore.projectLoadingStatus[project.id]
	}

	var body: some View {
		HStack(spacing: 10) {
			VStack(alignment: .leading, spacing: 1) {
				Text(project.name)
					.font(Theme.fontBody)
					.foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
					.lineLimit(1)

				if let status = loadingStatus {
					HStack(spacing: 4) {
						ProgressView()
							.controlSize(.mini)
							.scaleEffect(0.6)
							.frame(width: 10, height: 10)
						Text(status)
							.font(.system(size: 10))
							.foregroundStyle(Theme.accent)
							.lineLimit(1)
					}
				} else {
					Text(subtitle)
						.font(.system(size: 10))
						.foregroundStyle(Theme.textTertiary)
						.lineLimit(1)
				}
			}
			Spacer()
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
		.background(
			ZStack {
				if isHovering && !isSelected {
					RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.surfaceHover)
				}
				if isSelected {
					if let ns = selectionNamespace {
						RoundedRectangle(cornerRadius: Theme.radiusSm)
							.fill(Theme.surfaceActive)
							.matchedGeometryEffect(id: "selectionBackground", in: ns)
					} else {
						RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.surfaceActive)
					}
				}
			}
		)
		.overlay(
			HStack {
				if isSelected {
					if let ns = selectionNamespace {
						RoundedRectangle(cornerRadius: 1)
							.fill(Theme.accent)
							.frame(width: 2, height: 16)
							.matchedGeometryEffect(id: "selectionBar", in: ns)
					} else {
						RoundedRectangle(cornerRadius: 1)
							.fill(Theme.accent)
							.frame(width: 2, height: 16)
					}
				}
				Spacer()
			}
		)
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}
}
