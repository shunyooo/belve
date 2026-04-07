import SwiftUI

struct ProjectListView: View {
	let projects: [Project]
	@Binding var selectedProject: Project?
	@EnvironmentObject var notificationStore: NotificationStore
	var onAddProject: (() -> Void)?
	var onToggleSidebar: (() -> Void)?
	var onOpenNotifications: (() -> Void)?
	var onRenameProject: ((UUID, String) -> Void)?
	var onDeleteProject: ((UUID) -> Void)?

	@State private var renamingProjectId: UUID?
	@State private var renameText = ""
	@State private var contextMenuProjectId: UUID?
	@State private var contextMenuPosition: CGPoint = .zero

	var body: some View {
		ZStack {
			VStack(alignment: .leading, spacing: 0) {
				Spacer().frame(height: Theme.titlebarHeight)
				ScrollView {
					VStack(spacing: 2) {
						ForEach(projects) { project in
							if renamingProjectId == project.id {
								RenameField(text: $renameText) {
									if !renameText.isEmpty {
										onRenameProject?(project.id, renameText)
									}
									renamingProjectId = nil
								}
								.padding(.horizontal, 8)
							} else {
								Button {
									selectedProject = project
								} label: {
									ProjectRow(
										project: project,
										isSelected: selectedProject == project,
										unreadCount: notificationStore.unreadCount(for: project.id),
										agentState: notificationStore.agentStatus[project.id]
									)
								}
								.buttonStyle(.plain)
								.onRightClick { location in
									contextMenuPosition = location
									contextMenuProjectId = project.id
								}
							}
						}
					}
					.padding(.horizontal, 8)
				}
			}
			.overlay(alignment: .topTrailing) {
				HStack(spacing: 4) {
					SidebarIconButton(icon: "plus", action: { onAddProject?() })
					ZStack(alignment: .topTrailing) {
						SidebarIconButton(icon: "bell", action: { onOpenNotifications?() })
						if notificationStore.totalUnreadCount() > 0 {
							Circle()
								.fill(Theme.red)
								.frame(width: 8, height: 8)
								.offset(x: 2, y: -2)
						}
					}
					SidebarIconButton(icon: "sidebar.left", action: { onToggleSidebar?() })
				}
				.padding(.trailing, 6)
				.padding(.top, 4)
			}

			// Custom context menu overlay
			if contextMenuProjectId != nil {
				Color.clear
					.contentShape(Rectangle())
					.onTapGesture { contextMenuProjectId = nil }
					.onExitCommand { contextMenuProjectId = nil }

				ProjectContextMenu(
					position: contextMenuPosition,
					onRename: {
						if let id = contextMenuProjectId,
						   let project = projects.first(where: { $0.id == id }) {
							renameText = project.name
							renamingProjectId = id
						}
						contextMenuProjectId = nil
					},
					onDelete: {
						if let id = contextMenuProjectId {
							onDeleteProject?(id)
						}
						contextMenuProjectId = nil
					}
				)
				.transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
			}
		}
		.animation(.easeOut(duration: 0.12), value: contextMenuProjectId != nil)
	}
}

// MARK: - Custom Context Menu

struct ProjectContextMenu: View {
	let position: CGPoint
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
		.position(x: position.x + 80, y: position.y + 30)
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

// MARK: - Right Click Gesture

struct RightClickModifier: ViewModifier {
	let action: (CGPoint) -> Void

	func body(content: Content) -> some View {
		content.overlay(
			RightClickView(action: action)
		)
	}
}

struct RightClickView: NSViewRepresentable {
	let action: (CGPoint) -> Void

	func makeNSView(context: Context) -> RightClickNSView {
		let view = RightClickNSView()
		view.action = action
		return view
	}

	func updateNSView(_ nsView: RightClickNSView, context: Context) {
		nsView.action = action
	}

	class RightClickNSView: NSView {
		var action: ((CGPoint) -> Void)?

		override func rightMouseDown(with event: NSEvent) {
			let location = convert(event.locationInWindow, from: nil)
			let swiftUIPoint = CGPoint(x: location.x, y: bounds.height - location.y)
			action?(swiftUIPoint)
		}
	}
}

extension View {
	func onRightClick(perform action: @escaping (CGPoint) -> Void) -> some View {
		modifier(RightClickModifier(action: action))
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
	var unreadCount: Int = 0
	var agentState: AgentState?
	@State private var isHovering = false

	private var statusColor: Color {
		switch agentState?.status {
		case .running: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed: return Theme.green
		case .sessionStart: return Theme.accent
		default: return project.sshHost != nil ? Theme.accent : Theme.green
		}
	}

	private var subtitle: String {
		if project.isDevContainer {
			let label = project.containerImageName.map { ($0 as NSString).lastPathComponent } ?? "container"
			return "DevContainer: \(label)"
		} else if let host = project.sshHost {
			let short = host.components(separatedBy: ".").first ?? host
			return "SSH: \(short)"
		} else {
			return "~/\(project.remotePath.map { ($0 as NSString).lastPathComponent } ?? "")"
		}
	}

	var body: some View {
		HStack(spacing: 10) {
			Circle()
				.fill(statusColor)
				.frame(width: 7, height: 7)

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

			if unreadCount > 0 {
				Text("\(unreadCount)")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(.white)
					.padding(.horizontal, 5)
					.padding(.vertical, 1)
					.background(Theme.accent)
					.cornerRadius(6)
			}
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
