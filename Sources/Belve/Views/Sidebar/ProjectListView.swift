import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

/// Sidebar の session row を view 間 DD 移動するための payload。
/// 直接 Data に encode する DataRepresentation を使う (= Codable + Proxy で
/// 試したら SwiftUI の Attribute Graph 更新中に swift_bridgeObjectRelease で
/// crash したため、最小依存の Data 経路に切替え。2026-05-05)。
/// `.data` content type だが、within-app DD では typed dropDestination
/// (= for: PaneTransferToken.self) で解決されるので他 Data drop と混線しない。
struct PaneTransferToken: Transferable, Hashable {
	let paneId: UUID
	let sourceViewId: UUID
	let projectId: UUID

	private static let magic: [UInt8] = [0x42, 0x4C, 0x56, 0x50] // "BLVP"

	static var transferRepresentation: some TransferRepresentation {
		DataRepresentation(contentType: .data) { token in
			var data = Data(magic)
			data.append(token.paneId.uuidString.data(using: .utf8) ?? Data())
			data.append(0x7C) // '|'
			data.append(token.sourceViewId.uuidString.data(using: .utf8) ?? Data())
			data.append(0x7C)
			data.append(token.projectId.uuidString.data(using: .utf8) ?? Data())
			return data
		} importing: { data in
			guard data.count > 4, Array(data.prefix(4)) == magic else {
				throw CocoaError(.coderInvalidValue)
			}
			guard let payload = String(data: data.dropFirst(4), encoding: .utf8) else {
				throw CocoaError(.coderInvalidValue)
			}
			let parts = payload.split(separator: "|")
			guard parts.count == 3,
			      let paneId = UUID(uuidString: String(parts[0])),
			      let sourceViewId = UUID(uuidString: String(parts[1])),
			      let projectId = UUID(uuidString: String(parts[2])) else {
				throw CocoaError(.coderInvalidValue)
			}
			return PaneTransferToken(paneId: paneId, sourceViewId: sourceViewId, projectId: projectId)
		}
	}
}

struct ProjectListView: View {
	let projects: [Project]
	@Binding var selectedProject: Project?
	@EnvironmentObject var notificationStore: NotificationStore
	var onAddProject: (() -> Void)?
	var onToggleSidebar: (() -> Void)?
	var onRenameProject: ((UUID, String) -> Void)?
	var onDeleteProject: ((UUID) -> Void)?
	var onMoveProject: ((IndexSet, Int) -> Void)?
	var onTogglePin: ((UUID) -> Void)?
	var onFocusPane: ((UUID, String) -> Void)?
	var onSetProjectGroup: ((UUID, String?) -> Void)?
	var groupNames: [String] = []
	var collapsedGroups: Set<String> = []
	var onToggleGroupCollapse: ((String) -> Void)?
	var onRenameGroup: ((String, String) -> Void)?
	var uniqueGroupName: (() -> String)?
	var onMoveProjectToSection: ((UUID, String) -> Void)?
	@ObservedObject var activeCommandState: CommandAreaState
	/// CommandAreaStateManager 全体を観測 (= cross-view DD で pane が移動した
	/// 際に、active 以外の view の paneIdsForView lookup も再評価させるため)。
	@ObservedObject var stateManager: CommandAreaStateManager
	/// Returns the set of currently-existing pane UUIDs (as lowercase strings)
	/// for a given project. Used to filter the session list to panes that still
	/// exist in the UI.
	var paneIdsForProject: ((UUID) -> Set<String>)?
	/// 同上の view 版。view (= UI 主単位) 配下の pane UUID 集合を返す。
	/// view row 配下に session row を nest 表示するための引数 (Phase 5)。
	var paneIdsForView: ((UUID) -> Set<String>)?
	/// Cross-view DD で session pane を移動。(paneId, fromViewId, toViewId)。
	/// MainWindow が CommandAreaStateManager.movePane を呼ぶ。
	var onMovePaneToView: ((UUID, UUID, UUID) -> Void)?
	/// 親 (= MainWindow) から `projectStore.projectLoadingStatus[id]` を
	/// 取得する。ProjectListView 自身が projectStore を持つと、git 等の
	/// 無関係な @Published 変更で全 row が再 render → 選択 animation
	/// jank の元になるため、必要な値だけ closure で渡してもらう。
	var loadingStatusFor: ((UUID) -> String?)? = nil

	private static let pinnedKey = "__pinned__"

	@ObservedObject private var appConfig = AppConfig.shared
	@ObservedObject private var viewStore = ProjectViewStore.shared
	@State private var renamingProjectId: UUID?
	@State private var renameText = ""
	/// View row の inline rename 中の view id (= UUID set されてる時 TextField 表示)。
	@State private var renamingViewId: UUID?
	@State private var viewRenameText = ""
	@State private var renamingGroupName: String?
	@State private var groupRenameText: String = ""
	@State private var draggingProjectId: UUID?
	@State private var dropTargetIndex: Int?
	/// Projects selected for bulk operations. The primary selection
	/// (`selectedProject`) is always a member of this set when non-empty.
	@State private var selectedProjectIds: Set<UUID> = []
	/// Last clicked project id — used as the anchor for Shift+click range
	/// selection.
	@State private var rangeAnchorId: UUID?
	/// Section key (groupName / pinnedKey / "") currently being hovered during
	/// a drag. Used to highlight the target header.
	@State private var dragOverSectionKey: String?
	@Namespace private var selectionNamespace

	var body: some View {
		ZStack(alignment: .topLeading) {
			VStack(alignment: .leading, spacing: 0) {
				Spacer().frame(height: Theme.titlebarHeight)
				ScrollView {
					VStack(spacing: 2) {
						// Pinned section — implicit group, always appears first when non-empty.
						let pinned = projects.filter { $0.isPinned }
						if !pinned.isEmpty {
							groupSection(
								label: "Pinned",
								icon: "pin.fill",
								key: Self.pinnedKey,
								members: pinned
							)
						}

						// Named groups in first-appearance order. Pinned projects are already
						// rendered above and are skipped here.
						ForEach(groupNames, id: \.self) { groupName in
							let members = projects.filter { $0.groupName == groupName && !$0.isPinned }
							if !members.isEmpty {
								groupSection(
									label: groupName,
									icon: "folder",
									key: groupName,
									members: members
								)
							}
						}

						if dropTargetIndex == projects.count {
							dropIndicator()
						}

						// Bottom catcher: right-click opens the sidebar menu。
						// すべての project は必ず group に属するので、ここに drop
						// しても「グループから外す」ではなく「default group に
						// 戻す」挙動 (ProjectStore.moveProjectToSection で吸収)。
						Color.clear
							.frame(minHeight: 200)
							.contentShape(Rectangle())
							.overlay(SidebarRightClickDetector(
								onNewProject: { onAddProject?() },
								onNewGroup: { promptForNewGroupOnly() }
							))
							.onDrop(of: [.text], delegate: SectionDropDelegate(
								sectionKey: "",
								dragOverKey: $dragOverSectionKey,
								draggingProjectId: $draggingProjectId,
								selectedProjectIds: selectedProjectIds,
								onMove: { id, key in onMoveProjectToSection?(id, key) }
							))
							.onDrop(of: [.text], delegate: ProjectDropDelegate(
								targetIndex: projects.count,
								projects: projects,
								draggingProjectId: $draggingProjectId,
								dropTargetIndex: $dropTargetIndex,
								selectedProjectIds: selectedProjectIds,
								onMoveProject: onMoveProject,
								onMoveProjectToSection: onMoveProjectToSection
							))
					}
					.padding(.horizontal, 8)
				}
			}
			.overlay(alignment: .topTrailing) {
				HStack(spacing: 4) {
					SidebarIconButton(icon: "plus", action: { onAddProject?() })
					SidebarIconButton(
						icon: appConfig.viewMode == .tile ? "square.grid.2x2.fill" : "square.grid.2x2",
						action: {
							let next: ViewMode = (appConfig.viewMode == .tile) ? .project : .tile
							withAnimation(ViewMode.toggleAnimation(showing: next == .tile)) {
								appConfig.viewMode = next
							}
						}
					)
					SidebarIconButton(icon: "sidebar.left", action: { onToggleSidebar?() })
				}
				.padding(.trailing, 6)
				.padding(.top, 4)
			}
		}
		// 注意: ScrollView 全体に .animation(value:) を当てると 12+ row
		// の全 modifier が implicit animation 対象になる可能性がある。
		// 選択 highlight の animation は ProjectRow 内で背景表示に
		// .transition なり .animation で局所適用したい。
		// → main area との同期感優先で sidebar 切替は即時化。
		.onReceive(NotificationCenter.default.publisher(for: .belvePaneClosed)) { notif in
			if let paneId = notif.userInfo?["paneId"] as? String {
				notificationStore.archiveSessionsForPane(paneId)
			}
		}
	}

	// MARK: - Group Header

	/// Transition used when a group's members slide in/out on toggle.
	/// `.move(edge: .top)` caused rows to render above the group header
	/// during the animation (overflowing into the previous section).
	/// Plain opacity keeps the rows in place while the parent VStack animates
	/// the height change, so nothing escapes the section bounds.
	private var groupCollapseTransition: AnyTransition {
		.opacity
	}

	/// Renders one group (header + members container) and attaches a single
	/// `SectionDropDelegate` spanning the whole thing. Inner project rows still
	/// have their own `ProjectDropDelegate` which wins for drops exactly on
	/// rows (reorder); drops on the header or gutter fall through to this
	/// delegate (section move).
	@ViewBuilder
	private func groupSection(
		label: String,
		icon: String,
		key: String,
		members: [Project]
	) -> some View {
		VStack(spacing: 2) {
			groupHeader(label: label, icon: icon, key: key, count: members.count)
			if !collapsedGroups.contains(key) {
				groupMembersContainer {
					ForEach(Array(members.enumerated()), id: \.element.id) { idx, project in
						projectRowBlock(
							project: project,
							trailingSectionKey: idx == members.count - 1 ? key : nil
						)
					}
				}
			}
		}
		.onDrop(of: [.text], delegate: SectionDropDelegate(
			sectionKey: key,
			dragOverKey: $dragOverSectionKey,
			draggingProjectId: $draggingProjectId,
			selectedProjectIds: selectedProjectIds,
			onMove: { id, key in onMoveProjectToSection?(id, key) }
		))
	}

	/// Indented container used for every group's member rows (Pinned and named
	/// groups). A thin left rail makes the containment obvious so the user can
	/// tell at a glance which rows belong to a group. `.clipped()` keeps rows
	/// from escaping the container's bounds while the collapse transition is
	/// running — otherwise they briefly overlap adjacent sections.
	@ViewBuilder
	private func groupMembersContainer<Content: View>(
		@ViewBuilder content: () -> Content
	) -> some View {
		HStack(spacing: 0) {
			Rectangle()
				.fill(Theme.borderSubtle)
				.frame(width: 1)
				.padding(.leading, 10)
				.padding(.vertical, 2)
			VStack(spacing: 2) {
				content()
			}
			.padding(.leading, 6)
		}
		.clipped()
		.transition(groupCollapseTransition)
	}

	@ViewBuilder
	private func groupHeader(label: String, icon: String, key: String, count: Int) -> some View {
		if renamingGroupName == key && key != Self.pinnedKey {
			editableGroupHeader(icon: icon, key: key)
		} else {
			staticGroupHeader(label: label, icon: icon, key: key, count: count)
		}
	}

	private func staticGroupHeader(label: String, icon: String, key: String, count: Int) -> some View {
		let collapsed = collapsedGroups.contains(key)
		let isDropTarget = dragOverSectionKey == key
		// Using a plain HStack + tap gesture instead of Button so `.onDrop`
		// receives the drag session events reliably. SwiftUI's Button on macOS
		// was silently swallowing the drop before `performDrop` could fire.
		return HStack(spacing: 4) {
			Image(systemName: "chevron.right")
				.font(.system(size: 9, weight: .semibold))
				.rotationEffect(.degrees(collapsed ? 0 : 90))
				.foregroundStyle(Theme.textTertiary)
			Image(systemName: icon)
				.font(.system(size: 9))
				.foregroundStyle(isDropTarget ? Theme.accent : Theme.textTertiary)
			Text(label.uppercased())
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(isDropTarget ? Theme.accent : Theme.textTertiary)
				.tracking(0.5)
			Spacer()
			Text("\(count)")
				.font(.system(size: 10))
				.foregroundStyle(Theme.textTertiary.opacity(0.7))
		}
		.padding(.horizontal, 6)
		.padding(.top, 8)
		.padding(.bottom, 2)
		.background(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.fill(isDropTarget ? Theme.accent.opacity(0.15) : Color.clear)
				.padding(.horizontal, 2)
		)
		.contentShape(Rectangle())
		.onTapGesture {
			withAnimation(.easeInOut(duration: 0.22)) {
				onToggleGroupCollapse?(key)
			}
		}
		.animation(.easeInOut(duration: 0.15), value: collapsed)
		.animation(.easeInOut(duration: 0.12), value: isDropTarget)
		.contextMenu {
			if key != Self.pinnedKey {
				Button("Rename Group") { beginRenameGroup(key) }
			}
		}
	}

	private func editableGroupHeader(icon: String, key: String) -> some View {
		HStack(spacing: 4) {
			Image(systemName: "chevron.down")
				.font(.system(size: 9, weight: .semibold))
				.foregroundStyle(Theme.textTertiary)
			Image(systemName: icon)
				.font(.system(size: 9))
				.foregroundStyle(Theme.accent)
			GroupNameField(
				text: $groupRenameText,
				onCommit: { commitGroupRename(oldName: key) },
				onCancel: { renamingGroupName = nil }
			)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 6)
		.padding(.top, 8)
		.padding(.bottom, 2)
	}

	private func beginRenameGroup(_ name: String) {
		groupRenameText = name
		renamingGroupName = name
	}

	private func commitGroupRename(oldName: String) {
		let newName = groupRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
		if !newName.isEmpty && newName != oldName {
			onRenameGroup?(oldName, newName)
		}
		renamingGroupName = nil
	}

	/// Renders a single project row with the surrounding rename-edit / drop-indicator
	/// logic. Wrapped so grouped sections can call it with the same visual result as
	/// the original flat iteration.
	@ViewBuilder
	private func projectRowBlock(project: Project, trailingSectionKey: String? = nil) -> some View {
		let flatIndex = projects.firstIndex(where: { $0.id == project.id }) ?? 0
		Group {
			if renamingProjectId == project.id {
				RenameField(text: $renameText) {
					if !renameText.isEmpty {
						onRenameProject?(project.id, renameText)
					}
					renamingProjectId = nil
				}
				.padding(.horizontal, 8)
			} else {
				if dropTargetIndex == flatIndex && draggingProjectId != project.id {
					dropIndicator()
				}
				projectSection(project: project, index: flatIndex)
					.overlay(alignment: .bottom) {
						// When this row is the last member of its group AND a
						// drag is in progress, overlay the bottom ~18pt of the
						// row with a drop zone that inserts the dragged
						// project *after* this row while keeping it in the
						// current group. Only present during drag so it
						// doesn't capture clicks on the row.
						if let key = trailingSectionKey, draggingProjectId != nil {
							Color.clear
								.frame(height: 18)
								.contentShape(Rectangle())
								.onDrop(of: [.text], delegate: ProjectDropDelegate(
									targetIndex: flatIndex + 1,
									projects: projects,
									draggingProjectId: $draggingProjectId,
									dropTargetIndex: $dropTargetIndex,
									selectedProjectIds: selectedProjectIds,
									forcedSectionKey: key,
									onMoveProject: onMoveProject,
									onMoveProjectToSection: onMoveProjectToSection
								))
						}
					}
			}
		}
	}

	// MARK: - Project Section (project row + nested sessions)

	private func projectSection(project: Project, index: Int) -> some View {
		VStack(spacing: 0) {
			ProjectRow(
				project: project,
				isSelected: selectedProject == project,
				isMultiSelected: selectedProjectIds.contains(project.id) && selectedProjectIds.count > 1,
				agentState: notificationStore.agentStatus[project.id],
				selectionNamespace: selectionNamespace,
				loadingStatus: loadingStatusFor?(project.id)
			)
			.opacity(draggingProjectId == project.id ? 0.4 : 1.0)
			.overlay(
				DragSourceView(
					projectId: project.id,
					onDragStarted: { draggingProjectId = project.id },
					onClick: { modifiers in handleProjectClick(project, modifiers: modifiers) },
					onRightClick: { screenPoint in
						showProjectContextMenu(for: project, at: screenPoint)
					}
				)
			)
			.onDrop(of: [.text], delegate: ProjectDropDelegate(
				targetIndex: index,
				projects: projects,
				draggingProjectId: $draggingProjectId,
				dropTargetIndex: $dropTargetIndex,
				selectedProjectIds: selectedProjectIds,
				onMoveProject: onMoveProject,
				onMoveProjectToSection: onMoveProjectToSection
			))

			// Project → View → Session の 3 段 nest (Phase 5)。
			// view rows が agent session を内包する形 = view の pane に属する
			// session のみその view 配下に出る。Phase 2 までは "main" 1 view しか
			// 無いので全 session が main 配下に集まる。
			viewRows(for: project)
		}
	}

	/// Project 配下の view rows。view ごとに「view 行 + その view 配下の
	/// agent session 行」を nest 表示 (Phase 5)。
	/// View が 1 つだけ (= "main" のみ) なら view 行は省略して session 行だけ
	/// project 直下に出す (= UI のノイズ削減)。2 view 以上で初めて view 行を出す。
	/// View 追加は project context menu からのみ (sidebar の "+ New View" 削除)。
	@ViewBuilder
	private func viewRows(for project: Project) -> some View {
		let views = viewStore.views(for: project.id)
		let activeId = viewStore.activeView(for: project.id).id
		if views.count <= 1 {
			// View 1 個 → view 行を省略、session のみ project 直下に並べる
			let v = views.first ?? ProjectView.main(for: project.id)
			let sessions = sessionsForView(viewId: v.id, projectId: project.id)
			if !sessions.isEmpty {
				VStack(spacing: 1) {
					ForEach(sessions) { session in
						sessionRowDraggable(session: session, view: v, project: project)
					}
				}
				.padding(.leading, 16)
				.padding(.bottom, 4)
			}
		} else {
			// View 2 個以上 → view 行 + その下に session 行を nest
			VStack(spacing: 1) {
				ForEach(views) { v in
					viewRowButton(view: v, isActive: v.id == activeId, project: project)
					let sessions = sessionsForView(viewId: v.id, projectId: project.id)
					if !sessions.isEmpty {
						VStack(spacing: 1) {
							ForEach(sessions) { session in
								sessionRowDraggable(session: session, view: v, project: project)
							}
						}
						.padding(.leading, 12)
					}
				}
			}
			.padding(.leading, 16)
			.padding(.bottom, 4)
		}
	}

	@ViewBuilder
	private func sessionRowDraggable(session: AgentSession, view v: ProjectView, project: Project) -> some View {
		let base = SessionRow(
			session: session,
			isFocused: session.paneId.flatMap { UUID(uuidString: $0) } == activeCommandState.activePaneId
				&& selectedProject == project,
			onDismiss: {
				notificationStore.archiveSession(session.id)
			}
		)
		.onTapGesture {
			selectedProject = project
			viewStore.setActiveView(v.id, for: project.id)
			if let paneId = session.paneId {
				onFocusPane?(project.id, paneId)
			}
		}

		Group {
			if let paneIdString = session.paneId, let paneUUID = UUID(uuidString: paneIdString) {
				base.draggable(PaneTransferToken(
					paneId: paneUUID,
					sourceViewId: v.id,
					projectId: project.id
				)) {
					Text(session.lastUserPrompt ?? session.label ?? "Session")
						.font(.system(size: 11))
						.padding(6)
						.background(Theme.surface)
						.cornerRadius(4)
				}
			} else {
				base
			}
		}
		.overlay(
			RightClickArea { screenPoint in
				showSessionContextMenu(session: session, at: screenPoint)
			}
		)
	}

	@ViewBuilder
	private func viewRowButton(view v: ProjectView, isActive: Bool, project: Project) -> some View {
		let canDelete = viewStore.views(for: project.id).count > 1
		if renamingViewId == v.id {
			HStack(spacing: 6) {
				Image(systemName: isActive ? "circle.fill" : "circle")
					.font(.system(size: 7))
					.foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
				ViewNameField(
					text: $viewRenameText,
					onCommit: {
						let newName = viewRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
						if !newName.isEmpty {
							viewStore.renameView(v.id, in: project.id, to: newName)
						}
						renamingViewId = nil
					},
					onCancel: {
						renamingViewId = nil
					}
				)
			}
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
		} else {
			Button(action: {
				selectedProject = project
				viewStore.setActiveView(v.id, for: project.id)
			}) {
				HStack(spacing: 6) {
					Image(systemName: isActive ? "circle.fill" : "circle")
						.font(.system(size: 7))
						.foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
					Text(v.name)
						.font(.system(size: 11))
						.foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
						.lineLimit(1)
					Spacer()
				}
				.padding(.horizontal, 6)
				.padding(.vertical, 2)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.dropDestination(for: PaneTransferToken.self) { tokens, _ in
				guard let token = tokens.first,
				      token.projectId == project.id,
				      token.sourceViewId != v.id else { return false }
				onMovePaneToView?(token.paneId, token.sourceViewId, v.id)
				selectedProject = project
				viewStore.setActiveView(v.id, for: project.id)
				return true
			}
			.contextMenu {
				Button("Rename View") {
					viewRenameText = v.name
					renamingViewId = v.id
				}
				Button("Close View", role: .destructive) {
					viewStore.deleteView(v.id, from: project.id)
				}
				.disabled(!canDelete)
			}
		}
	}

	private func newViewButton(project: Project) -> some View {
		Button(action: {
			let new = viewStore.createView(for: project.id)
			selectedProject = project
			NSLog("[Belve] Created new view '%@' for project %@", new.name, project.name)
		}) {
			HStack(spacing: 6) {
				Image(systemName: "plus")
					.font(.system(size: 8, weight: .semibold))
					.foregroundStyle(Theme.textTertiary)
				Text("New View")
					.font(.system(size: 10))
					.foregroundStyle(Theme.textTertiary)
				Spacer()
			}
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	private func showSessionContextMenu(session: AgentSession, at screenPoint: NSPoint) {
		let paneId = session.paneId ?? ""
		let hasPane = !paneId.isEmpty
		let isEnabled = hasPane && AgentCompanionStore.shared.isCompanionEnabled(for: paneId)
		FloatingMenuPopup.shared.show(
			at: screenPoint,
			size: NSSize(width: 180, height: 90)
		) {
			VStack(alignment: .leading, spacing: 1) {
				if hasPane {
					ContextMenuItem(
						label: isEnabled ? "Hide Companion" : "Show Companion",
						icon: isEnabled ? "eye.slash" : "eye",
						action: { [weak notificationStore] in
							FloatingMenuPopup.shared.close()
							if isEnabled {
								AgentCompanionStore.shared.disableCompanion(for: paneId)
							} else {
								AgentCompanionStore.shared.enableCompanion(for: paneId)
							}
							_ = notificationStore
						}
					)
					ContextMenuDivider()
				}
				ContextMenuItem(
					label: "Dismiss Session",
					icon: "xmark.circle",
					isDestructive: true,
					action: { [weak notificationStore] in
						FloatingMenuPopup.shared.close()
						notificationStore?.archiveSession(session.id)
					}
				)
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
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.padding(4)
		}
	}

	// Sessions whose agent has ended are hidden from the sidebar even when
	// the pane still exists.
	private static let inactiveStatuses: Set<AgentStatus> = [.sessionEnd, .idle]

	/// 指定 view 配下の agent sessions。session の paneId が view の pane tree
	/// に含まれているものだけ返す。同 pane の重複は最新 updatedAt を残す。
	private func sessionsForView(viewId: UUID, projectId: UUID) -> [AgentSession] {
		let viewPaneIds = paneIdsForView?(viewId) ?? []
		guard !viewPaneIds.isEmpty else { return [] }
		let candidates = notificationStore.sessions.filter { s in
			guard s.projectId == projectId,
			      !s.isArchived,
			      !Self.inactiveStatuses.contains(s.status) else { return false }
			guard let paneId = s.paneId else { return false }
			return viewPaneIds.contains(paneId.lowercased())
		}
		var latestPerPane: [String: AgentSession] = [:]
		for s in candidates {
			guard let paneId = s.paneId else { continue }
			if let existing = latestPerPane[paneId] {
				if s.updatedAt > existing.updatedAt { latestPerPane[paneId] = s }
			} else {
				latestPerPane[paneId] = s
			}
		}
		return Array(latestPerPane.values).sorted { $0.updatedAt > $1.updatedAt }
	}

	// MARK: - Click handling

	/// Flat visual order used for Shift+click range selection — matches the
	/// render order (pinned → each named group)。グループ必須化により ungrouped
	/// 区分は廃止 (= 必ずどこかの group に属する)。
	private var flatVisibleProjects: [Project] {
		var result: [Project] = []
		let pinned = projects.filter { $0.isPinned }
		result.append(contentsOf: pinned)
		for name in groupNames {
			result.append(contentsOf: projects.filter { $0.groupName == name && !$0.isPinned })
		}
		return result
	}

	private func handleProjectClick(_ project: Project, modifiers: NSEvent.ModifierFlags) {
		let isShift = modifiers.contains(.shift)
		let isCmd = modifiers.contains(.command)
		let id = project.id

		if isShift, let anchor = rangeAnchorId, anchor != id {
			let visible = flatVisibleProjects
			if let a = visible.firstIndex(where: { $0.id == anchor }),
			   let b = visible.firstIndex(where: { $0.id == id }) {
				let range = min(a, b)...max(a, b)
				selectedProjectIds = Set(visible[range].map(\.id))
				selectedProject = project
			}
		} else if isCmd {
			if selectedProjectIds.contains(id) {
				selectedProjectIds.remove(id)
				// Primary selection should still be meaningful when possible.
				if selectedProject?.id == id {
					selectedProject = selectedProjectIds.first.flatMap { sid in
						projects.first(where: { $0.id == sid })
					}
				}
			} else {
				selectedProjectIds.insert(id)
				selectedProject = project
			}
			rangeAnchorId = id
		} else {
			selectedProjectIds = [id]
			selectedProject = project
			rangeAnchorId = id
		}
	}

	/// Resolve the targets for a context-menu action. Right-clicking a project
	/// that is part of the multi-selection operates on every selected project;
	/// right-clicking outside it operates on that single project.
	private func contextTargets(for project: Project) -> [UUID] {
		if selectedProjectIds.contains(project.id) && selectedProjectIds.count > 1 {
			return Array(selectedProjectIds)
		}
		return [project.id]
	}

	private func showProjectContextMenu(for project: Project, at screenPoint: NSPoint) {
		let targets = contextTargets(for: project)
		let bulk = targets.count > 1
		FloatingMenuPopup.shared.show(
			at: screenPoint,
			size: NSSize(width: 210, height: 380)
		) {
			ProjectContextMenu(
				isPinned: project.isPinned,
				currentGroup: project.groupName,
				existingGroups: groupNames,
				bulkCount: bulk ? targets.count : nil,
				onAddView: bulk ? nil : {
					FloatingMenuPopup.shared.close()
					let new = viewStore.createView(for: project.id)
					selectedProject = project
					NSLog("[Belve] Created new view '%@' via context menu for project %@", new.name, project.name)
				},
				onTogglePin: {
					FloatingMenuPopup.shared.close()
					for id in targets { onTogglePin?(id) }
				},
				onSetGroup: { name in
					FloatingMenuPopup.shared.close()
					for id in targets { onSetProjectGroup?(id, name) }
				},
				onNewGroup: {
					FloatingMenuPopup.shared.close()
					promptForNewGroup(projectIds: targets)
				},
				onRename: {
					FloatingMenuPopup.shared.close()
					// Rename always operates on the single clicked project — no
					// meaningful bulk semantics.
					renameText = project.name
					renamingProjectId = project.id
				},
				onDelete: {
					FloatingMenuPopup.shared.close()
					for id in targets { onDeleteProject?(id) }
				}
			)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.padding(4)
		}
	}

	/// Create a new group with a placeholder name, move the given projects into
	/// it, and immediately enter inline rename mode on the header so the user
	/// can type the real name.
	private func promptForNewGroup(projectIds: [UUID]) {
		guard !projectIds.isEmpty else { return }
		let placeholder = uniqueGroupName?() ?? "New Group"
		for id in projectIds { onSetProjectGroup?(id, placeholder) }
		beginRenameGroup(placeholder)
	}

	/// Empty-area "New Group" variant: uses the current multi-selection, or
	/// the single selected project, or the first project overall. Runs the
	/// same inline flow.
	private func promptForNewGroupOnly() {
		let targets: [UUID]
		if selectedProjectIds.count > 1 {
			targets = Array(selectedProjectIds)
		} else if let id = selectedProject?.id {
			targets = [id]
		} else if let id = projects.first?.id {
			targets = [id]
		} else {
			return
		}
		promptForNewGroup(projectIds: targets)
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
	var onDismiss: (() -> Void)? = nil
	@State private var isHovering = false

	/// Sessions in `.sessionStart` are idle (claude is waiting for user input
	/// after launch); only `.running` and `.waiting` should look "live" in the
	/// sidebar.
	private var isActive: Bool {
		session.status == .running || session.status == .waiting
	}

	/// Primary text shown in the session row. Falls back to "Ready" for the
	/// `sessionStart` state so the row reads as idle instead of showing the
	/// raw hook message ("started").
	private var primaryText: String {
		if let prompt = session.lastUserPrompt, !prompt.isEmpty { return prompt }
		if let label = session.label, !label.isEmpty { return label }
		if session.status == .sessionStart { return "Ready" }
		return session.message
	}

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			VStack {
				Spacer().frame(height: 3)
				// Per-session avatar (= companion と同期)。未設定なら global style。
				StatusIndicator(
					status: session.subagentCount > 0 ? .runningSubagent : session.status,
					styleOverride: session.paneId.flatMap { AgentCompanionStore.shared.avatarStyle(for: $0) }
				)
			}

			VStack(alignment: .leading, spacing: 2) {
				Text(primaryText)
					.font(.system(size: 11, weight: isActive ? .medium : .regular))
					.foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
					.lineLimit(2)
					.frame(maxWidth: .infinity, alignment: .leading)

				// 詳細行: 状態ごとに 1 行だけ表示。content によらず高さ揃えるため
				// 常に Group を出して line を予約する (=空文字でも line height ぶん確保)。
				Group {
					if let tool = session.currentTool {
						HStack(spacing: 3) {
							Image(systemName: "wrench.and.screwdriver")
								.font(.system(size: 8))
							Text(tool)
								.lineLimit(1)
						}
						.font(.system(size: 9))
						.foregroundStyle(Theme.accent)
					} else if session.status == .waiting {
						Text(session.message)
							.font(.system(size: 9))
							.foregroundStyle(Theme.yellow)
							.lineLimit(1)
					} else if session.status == .completed {
						Text(session.lastAgentActivity ?? "Completed")
							.font(.system(size: 9))
							.foregroundStyle(Theme.textTertiary)
							.lineLimit(1)
					} else if isActive {
						Text("Thinking...")
							.font(.system(size: 9))
							.foregroundStyle(Theme.textTertiary)
							.lineLimit(1)
					} else {
						Text(" ")
							.font(.system(size: 9))
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)

				Text(session.updatedAt.relativeString)
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary.opacity(0.6))
			}

			Spacer(minLength: 0)
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 5)
		// 内容 (prompt / tool / detail) によって row の高さが伸縮しないように固定。
		// 56pt = primary 2行 (= 11pt × 2) + 詳細 1行 (= 9pt) + timestamp 1行 (= 9pt)
		// + padding 上下 5pt × 2 + 各行間隔 ≈ 56pt で収まる。
		.frame(height: 56, alignment: .top)
		.clipped()
		.background(
			RoundedRectangle(cornerRadius: 4)
				.fill(isFocused ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
		)
		.contextMenu {
			if let onDismiss {
				Button(action: onDismiss) {
					Label("Dismiss", systemImage: "xmark")
				}
			}
		}
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
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

// MARK: - Section Drop Delegate

/// Drop target attached to each group header (including the Pinned section).
/// Accepts a project being dragged and moves it into the target section, or
/// applies the same move to every selected project when the drag originated
/// from a member of the current multi-selection.
struct SectionDropDelegate: DropDelegate {
	let sectionKey: String
	@Binding var dragOverKey: String?
	@Binding var draggingProjectId: UUID?
	let selectedProjectIds: Set<UUID>
	let onMove: (UUID, String) -> Void

	func dropEntered(info: DropInfo) {
		withAnimation(.easeOut(duration: 0.12)) { dragOverKey = sectionKey }
	}

	func dropExited(info: DropInfo) {
		if dragOverKey == sectionKey {
			withAnimation(.easeOut(duration: 0.12)) { dragOverKey = nil }
		}
	}

	func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

	func validateDrop(info: DropInfo) -> Bool { draggingProjectId != nil }

	func performDrop(info: DropInfo) -> Bool {
		guard let dragged = draggingProjectId else { reset(); return false }
		let ids: [UUID] = (selectedProjectIds.contains(dragged) && selectedProjectIds.count > 1)
			? Array(selectedProjectIds)
			: [dragged]
		for id in ids { onMove(id, sectionKey) }
		reset()
		return true
	}

	private func reset() {
		withAnimation(.easeOut(duration: 0.12)) {
			dragOverKey = nil
			draggingProjectId = nil
		}
	}
}

struct ProjectDropDelegate: DropDelegate {
	let targetIndex: Int
	let projects: [Project]
	@Binding var draggingProjectId: UUID?
	@Binding var dropTargetIndex: Int?
	let selectedProjectIds: Set<UUID>
	/// When set, overrides the section inferred from neighbouring rows. Used
	/// for the trailing drop zone at the bottom of a group: the flat index
	/// would otherwise point at the first row of the next group and the
	/// project would land there instead.
	var forcedSectionKey: String? = nil
	var onMoveProject: ((IndexSet, Int) -> Void)?
	var onMoveProjectToSection: ((UUID, String) -> Void)?

	func dropEntered(info: DropInfo) {
		withAnimation(.easeOut(duration: 0.15)) { dropTargetIndex = targetIndex }
	}

	func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

	func performDrop(info: DropInfo) -> Bool {
		guard let dragId = draggingProjectId,
			  let sourceIndex = projects.firstIndex(where: { $0.id == dragId }) else {
			reset(); return false
		}

		// If the drop lands next to an existing row, inherit that row's
		// section (Pinned / group / ungrouped) so dragging between grouped
		// rows moves the project into that group. Drops past the last row
		// (targetIndex == projects.count) don't infer — they preserve the
		// dragged project's current membership. `forcedSectionKey` overrides
		// inference (used for per-group trailing drop zones).
		let inferredKey: String? = forcedSectionKey ?? (
			(targetIndex < projects.count)
				? Self.sectionKey(for: projects[targetIndex])
				: (targetIndex > 0 ? Self.sectionKey(for: projects[targetIndex - 1]) : nil)
		)

		// Apply section change to the dragged project (and the rest of the
		// multi-selection if it's part of one).
		if let sectionKey = inferredKey {
			let source = projects[sourceIndex]
			if Self.sectionKey(for: source) != sectionKey {
				let ids: [UUID] = (selectedProjectIds.contains(dragId) && selectedProjectIds.count > 1)
					? Array(selectedProjectIds)
					: [dragId]
				for id in ids { onMoveProjectToSection?(id, sectionKey) }
			}
		}

		let dest = targetIndex
		if sourceIndex != dest && sourceIndex + 1 != dest {
			onMoveProject?(IndexSet(integer: sourceIndex), dest)
		}
		reset(); return true
	}

	func dropExited(info: DropInfo) {
		// Drag が cancel された / 別 delegate に移った時に insert line が
		// 残らないよう、自分の index が表示中なら消す。別 row への hover で
		// 上書きが先に走るケースは dropEntered 側で正しく更新される。
		if dropTargetIndex == targetIndex {
			withAnimation(.easeOut(duration: 0.15)) { dropTargetIndex = nil }
		}
	}
	func validateDrop(info: DropInfo) -> Bool { draggingProjectId != nil }

	private func reset() {
		withAnimation(.easeOut(duration: 0.15)) {
			draggingProjectId = nil
			dropTargetIndex = nil
		}
	}

	/// Match the keying used by `SectionDropDelegate` and
	/// `ProjectStore.moveProjectToSection` so an inferred drop target flows
	/// through the same codepath as explicit section drops.
	private static func sectionKey(for project: Project) -> String {
		if project.isPinned { return "__pinned__" }
		return project.groupName.isEmpty ? "" : project.groupName
	}
}

// MARK: - Context Menu

struct ProjectContextMenu: View {
	var isPinned: Bool = false
	var currentGroup: String? = nil
	var existingGroups: [String] = []
	/// When set, the menu is operating on a multi-selection of this size.
	/// Rename is hidden (no sensible bulk semantics); a header row announces
	/// the count so the user knows the action is bulk.
	var bulkCount: Int? = nil
	/// nil の時は "Add View" 項目を出さない (= bulk 選択時など)。
	var onAddView: (() -> Void)? = nil
	var onTogglePin: (() -> Void)?
	var onSetGroup: ((String?) -> Void)?
	var onNewGroup: (() -> Void)?
	let onRename: () -> Void
	let onDelete: () -> Void

	@State private var showGroupSubmenu = false

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			if let count = bulkCount {
				Text("\(count) projects selected")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(Theme.accent)
					.padding(.horizontal, 10)
					.padding(.vertical, 4)
				ContextMenuDivider()
			}
			if let onAddView {
				ContextMenuItem(label: "Add View", icon: "plus.rectangle.on.rectangle", action: onAddView)
				ContextMenuDivider()
			}
			if let onTogglePin {
				ContextMenuItem(
					label: isPinned ? "Unpin" : "Pin",
					icon: isPinned ? "pin.slash" : "pin",
					action: onTogglePin
				)
				ContextMenuDivider()
			}
			if onSetGroup != nil {
				groupSection
				ContextMenuDivider()
			}
			if bulkCount == nil {
				ContextMenuItem(label: "Rename", icon: "pencil", action: onRename)
				ContextMenuDivider()
			}
			ContextMenuItem(
				label: bulkCount.map { "Delete \($0) Projects" } ?? "Delete",
				icon: "trash",
				isDestructive: true,
				action: onDelete
			)
		}
		.padding(.vertical, 4)
		.frame(width: 180)
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

	/// "Move to Group" expander. Inline (not a flyout submenu) because the sidebar
	/// is narrow — a right-side flyout would be clipped by the window edge.
	private var groupSection: some View {
		VStack(alignment: .leading, spacing: 1) {
			Button(action: { withAnimation(.easeOut(duration: 0.12)) { showGroupSubmenu.toggle() } }) {
				HStack(spacing: 8) {
					Image(systemName: "folder")
						.font(.system(size: 11))
						.frame(width: 16)
					Text("Move to Group")
						.font(.system(size: 12))
					Spacer()
					Image(systemName: "chevron.right")
						.font(.system(size: 9))
						.rotationEffect(.degrees(showGroupSubmenu ? 90 : 0))
				}
				.foregroundStyle(Theme.textSecondary)
				.padding(.horizontal, 10)
				.padding(.vertical, 5)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)

			if showGroupSubmenu {
				VStack(alignment: .leading, spacing: 1) {
					ForEach(existingGroups, id: \.self) { name in
						let isCurrent = name == currentGroup
						ContextMenuItem(
							label: name + (isCurrent ? "  ✓" : ""),
							icon: "folder",
							action: { onSetGroup?(name) }
						)
					}
					if !existingGroups.isEmpty {
						ContextMenuDivider()
					}
					ContextMenuItem(label: "New Group…", icon: "plus", action: { onNewGroup?() })
					if currentGroup != nil {
						ContextMenuItem(
							label: "Remove from Group",
							icon: "xmark",
							action: { onSetGroup?(nil) }
						)
					}
				}
				.padding(.leading, 12)
				.transition(.opacity.combined(with: .move(edge: .top)))
			}
		}
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

// MARK: - Right Click Area (session row context menu 用)

struct RightClickArea: NSViewRepresentable {
	let onRightClick: (CGPoint) -> Void

	func makeNSView(context: Context) -> RightClickNSView {
		let v = RightClickNSView()
		v.onRightClick = onRightClick
		return v
	}

	func updateNSView(_ nsView: RightClickNSView, context: Context) {
		nsView.onRightClick = onRightClick
	}

	final class RightClickNSView: NSView {
		var onRightClick: ((CGPoint) -> Void)?

		override func rightMouseDown(with event: NSEvent) {
			let screenPoint = NSEvent.mouseLocation
			onRightClick?(screenPoint)
		}

		override func hitTest(_ aPoint: NSPoint) -> NSView? {
			// 左クリックは素通し (= tap gesture を邪魔しない)。
			// 右クリックだけ intercept。
			let event = NSApp.currentEvent
			if event?.type == .rightMouseDown { return super.hitTest(aPoint) }
			return nil
		}
	}
}

// MARK: - Drag Source

struct DragSourceView: NSViewRepresentable {
	let projectId: UUID
	let onDragStarted: () -> Void
	let onClick: (NSEvent.ModifierFlags) -> Void
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
		var onClick: ((NSEvent.ModifierFlags) -> Void)?
		var onRightClick: ((CGPoint) -> Void)?
		private var mouseDownLocation: NSPoint?
		private var didDrag = false
		private var mouseDownModifiers: NSEvent.ModifierFlags = []
		private let dragThreshold: CGFloat = 4

		override func mouseDown(with event: NSEvent) {
			mouseDownLocation = event.locationInWindow
			mouseDownModifiers = event.modifierFlags
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
			if !didDrag { onClick?(mouseDownModifiers) }
			mouseDownLocation = nil
			didDrag = false
		}

		override func rightMouseDown(with event: NSEvent) {
			guard let window = self.window else { return }
			// Emit the click location in screen coords so callers can anchor a
			// NSPanel-based popup at the cursor without fighting SwiftUI coord
			// spaces.
			let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
			onRightClick?(screenPoint)
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

// MARK: - Sidebar Right-Click Detector

/// Detects right-clicks over empty sidebar space and shows a styled popup
/// anchored to the cursor. Uses `FloatingMenuPopup` (SwiftUI inside NSPanel)
/// so positioning matches the cursor in any window style.
struct SidebarRightClickDetector: NSViewRepresentable {
	let onNewProject: () -> Void
	let onNewGroup: () -> Void

	func makeNSView(context: Context) -> DetectorNSView {
		let view = DetectorNSView()
		view.onNewProject = onNewProject
		view.onNewGroup = onNewGroup
		return view
	}

	func updateNSView(_ nsView: DetectorNSView, context: Context) {
		nsView.onNewProject = onNewProject
		nsView.onNewGroup = onNewGroup
	}

	class DetectorNSView: NSView {
		var onNewProject: (() -> Void)?
		var onNewGroup: (() -> Void)?

		override func rightMouseDown(with event: NSEvent) {
			guard let window = self.window else { return }
			let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
			let captured = (onNewProject, onNewGroup)
			Task { @MainActor in
				FloatingMenuPopup.shared.show(
					at: screenPoint,
					size: NSSize(width: 190, height: 80)
				) {
					SidebarContextMenuContent(
						onNewProject: {
							FloatingMenuPopup.shared.close()
							captured.0?()
						},
						onNewGroup: {
							FloatingMenuPopup.shared.close()
							captured.1?()
						}
					)
				}
			}
		}
	}
}

/// Styled SwiftUI content shown inside the floating popup for empty-area clicks.
private struct SidebarContextMenuContent: View {
	let onNewProject: () -> Void
	let onNewGroup: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			ContextMenuItem(label: "New Project", icon: "plus", action: onNewProject)
			ContextMenuDivider()
			ContextMenuItem(label: "New Group…", icon: "folder.badge.plus", action: onNewGroup)
		}
		.padding(.vertical, 4)
		.frame(width: 180)
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
		.padding(4) // breathing room for shadow/border against panel edge
	}
}

// MARK: - Group Name Field (inline rename on the group header)

struct GroupNameField: View {
	@Binding var text: String
	let onCommit: () -> Void
	let onCancel: () -> Void
	@FocusState private var isFocused: Bool

	var body: some View {
		TextField("Group name", text: $text)
			.textFieldStyle(.plain)
			.font(.system(size: 10, weight: .semibold))
			.tracking(0.5)
			.foregroundStyle(Theme.textPrimary)
			.padding(.horizontal, 4)
			.padding(.vertical, 2)
			.background(RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceActive))
			.overlay(
				RoundedRectangle(cornerRadius: 3)
					.strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1)
			)
			.focused($isFocused)
			.onSubmit(onCommit)
			.onExitCommand(perform: onCancel)
			.onAppear {
				isFocused = true
				// Select-all so the placeholder is overwritten on first keystroke.
				DispatchQueue.main.async {
					NSApp.keyWindow?.firstResponder?
						.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
				}
			}
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
			.background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.surfaceActive))
			.focused($isFocused)
			.onAppear { isFocused = true }
			.onSubmit { onCommit() }
			.onExitCommand { onCommit() }
	}
}

/// View row inline rename 用 small TextField (RenameField より paddingsmall, font 11pt)。
struct ViewNameField: View {
	@Binding var text: String
	let onCommit: () -> Void
	let onCancel: () -> Void
	@FocusState private var isFocused: Bool

	var body: some View {
		TextField("View name", text: $text)
			.textFieldStyle(.plain)
			.font(.system(size: 11))
			.foregroundStyle(Theme.textPrimary)
			.padding(.horizontal, 4)
			.padding(.vertical, 1)
			.background(RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceActive))
			.focused($isFocused)
			.onAppear { isFocused = true }
			.onSubmit { onCommit() }
			.onExitCommand { onCancel() }
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
	/// True when part of a multi-selection (Shift/Cmd click). Gets a subtler
	/// highlight than the primary selection so the focus row is still obvious.
	var isMultiSelected: Bool = false
	var agentState: AgentState?
	var selectionNamespace: Namespace.ID?
	/// 親から明示的に渡してもらう。`@EnvironmentObject projectStore` を
	/// 観察してると git 更新など無関係な @Published 変更でも全 row が
	/// 再 render されて、選択切替の animation がカクつく原因になる。
	var loadingStatus: String? = nil
	@State private var isHovering = false

	private var subtitle: String {
		let label = project.provider.displayLabel
		if !label.isEmpty { return label }
		if let path = project.path {
			return "~/\((path as NSString).lastPathComponent)"
		}
		return ""
	}

	var body: some View {
		HStack(spacing: 10) {
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 4) {
					if project.isPinned {
						Image(systemName: "pin.fill")
							.font(.system(size: 9))
							.foregroundStyle(Theme.accent)
					}
					Text(project.name)
						.font(Theme.fontBody)
						.foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
						.lineLimit(1)
				}

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
				if isHovering && !isSelected && !isMultiSelected {
					RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.surfaceHover)
				}
				if isMultiSelected && !isSelected {
					RoundedRectangle(cornerRadius: Theme.radiusSm)
						.fill(Theme.accent.opacity(0.18))
				}
				// 選択 highlight は animation 無しの即時切替に戻した。
				// 経緯は `docs/notes/2026-04-22-sidebar-animation.md` 参照。
				if isSelected {
					RoundedRectangle(cornerRadius: Theme.radiusSm)
						.fill(Theme.surfaceActive)
				}
			}
		)
		.overlay(
			HStack {
				if isSelected {
					RoundedRectangle(cornerRadius: 1)
						.fill(Theme.accent)
						.frame(width: 2, height: 16)
				}
				Spacer()
			}
		)
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}
}
