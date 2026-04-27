import SwiftUI

/// Tile view 上部のフィルタバー: status filter (segmented) + project picker (popover)。
struct TileFilterBar: View {
	@ObservedObject private var filterState = TileFilterState.shared
	@EnvironmentObject var projectStore: ProjectStore
	@State private var showProjectPicker = false

	let projectsForGroup: [(group: String, projects: [Project])]

	var body: some View {
		HStack(spacing: 12) {
			statusFilterPicker
			Divider().frame(height: 18)
			projectFilterButton
			Divider().frame(height: 18)
			sortPicker
			Spacer()
			layoutModePicker
			Divider().frame(height: 18)
			columnStepper
			if filterState.layoutMode == .grid {
				Divider().frame(height: 18)
				heightStepper
			}
			Divider().frame(height: 18)
			headerStepper
			Divider().frame(height: 18)
			paneCountLabel
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
		.background(Theme.surface)
	}

	private var sortPicker: some View {
		Menu {
			Picker("", selection: $filterState.sortOrder) {
				ForEach(TileFilterState.SortOrder.allCases) { order in
					Label(order.label, systemImage: order.icon).tag(order)
				}
			}
			.pickerStyle(.inline)
			.labelsHidden()
		} label: {
			Text("⇅ Sort: \(filterState.sortOrder.label) ▾")
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(Theme.textSecondary)
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(RoundedRectangle(cornerRadius: 4).fill(Theme.bg.opacity(0.6)))
		}
		.menuStyle(.borderlessButton)
		.menuIndicator(.hidden)
		.fixedSize()
		.help("Sort tiles")
	}

	private var heightStepper: some View {
		HStack(spacing: 4) {
			Image(systemName: "rectangle.split.1x2")
				.font(.system(size: 10))
				.foregroundStyle(Theme.textTertiary)
			Button(action: { filterState.rowsPerScreen -= 1 }) {
				Image(systemName: "minus")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(filterState.rowsPerScreen > 1 ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
					.frame(width: 16, height: 16)
					.background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg.opacity(0.6)))
			}
			.buttonStyle(.plain)
			.disabled(filterState.rowsPerScreen <= 1)

			Text("\(filterState.rowsPerScreen)")
				.font(.system(size: 11, weight: .medium, design: .monospaced))
				.foregroundStyle(Theme.textPrimary)
				.frame(minWidth: 14)

			Button(action: { filterState.rowsPerScreen += 1 }) {
				Image(systemName: "plus")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(filterState.rowsPerScreen < 8 ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
					.frame(width: 16, height: 16)
					.background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg.opacity(0.6)))
			}
			.buttonStyle(.plain)
			.disabled(filterState.rowsPerScreen >= 8)
		}
		.help("Visible rows per screen (1-8)")
	}

	private var headerStepper: some View {
		HStack(spacing: 4) {
			Image(systemName: "rectangle.topthird.inset.filled")
				.font(.system(size: 10))
				.foregroundStyle(Theme.textTertiary)
			Button(action: { filterState.headerHeight -= 2 }) {
				Image(systemName: "minus")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(filterState.headerHeight > 0 ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
					.frame(width: 16, height: 16)
					.background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg.opacity(0.6)))
			}
			.buttonStyle(.plain)
			.disabled(filterState.headerHeight <= 0)

			Text("\(Int(filterState.headerHeight))")
				.font(.system(size: 11, weight: .medium, design: .monospaced))
				.foregroundStyle(Theme.textPrimary)
				.frame(minWidth: 20)

			Button(action: { filterState.headerHeight += 2 }) {
				Image(systemName: "plus")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(filterState.headerHeight < 40 ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
					.frame(width: 16, height: 16)
					.background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg.opacity(0.6)))
			}
			.buttonStyle(.plain)
			.disabled(filterState.headerHeight >= 40)
		}
		.help("Tile header height (0-40pt, 0 hides header)")
	}

	private var layoutModePicker: some View {
		HStack(spacing: 2) {
			ForEach(TileFilterState.LayoutMode.allCases) { mode in
				let active = filterState.layoutMode == mode
				Button(action: { filterState.layoutMode = mode }) {
					Image(systemName: mode.icon)
						.font(.system(size: 11))
						.foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
						.frame(width: 22, height: 18)
						.background(
							RoundedRectangle(cornerRadius: 3)
								.fill(active ? Theme.surfaceActive : Color.clear)
						)
				}
				.buttonStyle(.plain)
				.help(mode == .grid ? "Grid layout" : "Horizontal row")
			}
		}
		.padding(2)
		.background(RoundedRectangle(cornerRadius: 4).fill(Theme.bg.opacity(0.6)))
	}

	private var columnStepper: some View {
		HStack(spacing: 4) {
			Image(systemName: "rectangle.split.3x1")
				.font(.system(size: 10))
				.foregroundStyle(Theme.textTertiary)
			Button(action: { filterState.columnCount -= 1 }) {
				Image(systemName: "minus")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(filterState.columnCount > 1 ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
					.frame(width: 16, height: 16)
					.background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg.opacity(0.6)))
			}
			.buttonStyle(.plain)
			.disabled(filterState.columnCount <= 1)

			Text("\(filterState.columnCount)")
				.font(.system(size: 11, weight: .medium, design: .monospaced))
				.foregroundStyle(Theme.textPrimary)
				.frame(minWidth: 14)

			Button(action: { filterState.columnCount += 1 }) {
				Image(systemName: "plus")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(filterState.columnCount < 8 ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
					.frame(width: 16, height: 16)
					.background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg.opacity(0.6)))
			}
			.buttonStyle(.plain)
			.disabled(filterState.columnCount >= 8)
		}
		.help(filterState.layoutMode == .grid ? "Grid columns (1-8)" : "Visible tiles per row (1-8)")
	}

	private var statusFilterPicker: some View {
		HStack(spacing: 4) {
			ForEach(TileFilterState.StatusFilter.allCases) { f in
				Button(action: { filterState.statusFilter = f }) {
					Text(f.label)
						.font(.system(size: 11, weight: filterState.statusFilter == f ? .semibold : .regular))
						.foregroundStyle(filterState.statusFilter == f ? Theme.textPrimary : Theme.textSecondary)
						.padding(.horizontal, 10)
						.padding(.vertical, 4)
						.background(
							RoundedRectangle(cornerRadius: 4)
								.fill(filterState.statusFilter == f ? Theme.surfaceActive : Color.clear)
						)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(2)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(Theme.bg.opacity(0.6))
		)
	}

	private var projectFilterButton: some View {
		Button(action: { showProjectPicker.toggle() }) {
			HStack(spacing: 4) {
				Image(systemName: "folder")
					.font(.system(size: 10))
				Text(projectFilterLabel)
					.font(.system(size: 11))
				Image(systemName: "chevron.down")
					.font(.system(size: 8))
			}
			.foregroundStyle(Theme.textSecondary)
			.padding(.horizontal, 10)
			.padding(.vertical, 4)
			.background(
				RoundedRectangle(cornerRadius: 4)
					.fill(Theme.bg.opacity(0.6))
			)
		}
		.buttonStyle(.plain)
		.popover(isPresented: $showProjectPicker, arrowEdge: .bottom) {
			projectPickerContent
				.frame(width: 280)
				.padding(10)
		}
	}

	private var projectFilterLabel: String {
		if filterState.selectedProjectIds.isEmpty {
			return "All projects"
		}
		return "\(filterState.selectedProjectIds.count) project\(filterState.selectedProjectIds.count == 1 ? "" : "s")"
	}

	private var projectPickerContent: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Text("Filter projects")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
				Spacer()
				Button("Clear") {
					filterState.selectedProjectIds.removeAll()
				}
				.font(.system(size: 10))
				.buttonStyle(.plain)
				.foregroundStyle(Theme.accent)
				.disabled(filterState.selectedProjectIds.isEmpty)
			}
			Divider()
			ScrollView {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(projectsForGroup, id: \.group) { entry in
						Text(entry.group)
							.font(.system(size: 9, weight: .semibold))
							.foregroundStyle(Theme.textTertiary)
							.padding(.top, 4)
						ForEach(entry.projects) { project in
							projectCheckRow(project)
						}
					}
				}
			}
			.frame(maxHeight: 320)
		}
	}

	private func projectCheckRow(_ project: Project) -> some View {
		let isSelected = filterState.selectedProjectIds.contains(project.id)
		return Button(action: {
			if isSelected {
				filterState.selectedProjectIds.remove(project.id)
			} else {
				filterState.selectedProjectIds.insert(project.id)
			}
		}) {
			HStack(spacing: 6) {
				Image(systemName: isSelected ? "checkmark.square.fill" : "square")
					.font(.system(size: 11))
					.foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
				Text(project.name)
					.font(.system(size: 11))
					.foregroundStyle(Theme.textPrimary)
				Spacer()
			}
			.padding(.vertical, 2)
		}
		.buttonStyle(.plain)
	}

	private var paneCountLabel: some View {
		let total = PaneHostRegistry.shared.allPanes().count
		return Text("\(total) panes")
			.font(.system(size: 10))
			.foregroundStyle(Theme.textTertiary)
	}
}
