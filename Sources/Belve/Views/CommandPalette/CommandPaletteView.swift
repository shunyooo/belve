import SwiftUI

struct PaletteCommand: Identifiable {
	let id = UUID()
	let title: String
	let icon: String
	let keepOpen: Bool
	let action: () -> Void

	init(title: String, icon: String, keepOpen: Bool = false, action: @escaping () -> Void) {
		self.title = title
		self.icon = icon
		self.keepOpen = keepOpen
		self.action = action
	}
}

struct CommandPaletteView: View {
	@Binding var isPresented: Bool
	let commands: [PaletteCommand]
	@State private var query = ""
	@State private var selectedIndex = 0
	@FocusState private var isSearchFocused: Bool

	private var filtered: [PaletteCommand] {
		if query.isEmpty { return commands }
		return commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
	}

	var body: some View {
		VStack(spacing: 0) {
			// Search field
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 12))
					.foregroundStyle(Theme.textTertiary)
				TextField("Type a command...", text: $query)
					.textFieldStyle(.plain)
					.font(.system(size: 14))
					.foregroundStyle(Theme.textPrimary)
					.focused($isSearchFocused)
					.onSubmit {
						executeSelected()
					}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 10)

			Theme.border
				.frame(height: 1)

			// Command list
			ScrollView {
				VStack(spacing: 0) {
					ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
						CommandRow(
							command: command,
							isSelected: index == selectedIndex
						)
						.onTapGesture {
							execute(command)
						}
					}
				}
			}
			.frame(maxHeight: 500)
		}
		.frame(width: 400)
		.background(Theme.surface)
		.cornerRadius(Theme.radiusLg)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusLg)
				.stroke(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.4), radius: 20, y: 8)
		.onKeyPress(.upArrow) {
			selectedIndex = max(0, selectedIndex - 1)
			return .handled
		}
		.onKeyPress(.downArrow) {
			selectedIndex = min(filtered.count - 1, selectedIndex + 1)
			return .handled
		}
		.onKeyPress(.return) {
			executeSelected()
			return .handled
		}
		.onKeyPress(.escape) {
			isPresented = false
			return .handled
		}
		.onAppear {
			isSearchFocused = true
		}
		.onChange(of: query) {
			selectedIndex = 0
		}
	}

	private func executeSelected() {
		guard selectedIndex < filtered.count else { return }
		execute(filtered[selectedIndex])
	}

	private func execute(_ command: PaletteCommand) {
		if !command.keepOpen {
			isPresented = false
		}
		query = ""
		selectedIndex = 0
		command.action()
	}
}

struct CommandRow: View {
	let command: PaletteCommand
	let isSelected: Bool
	@State private var isHovering = false

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: command.icon)
				.font(.system(size: 12))
				.foregroundStyle(Theme.textSecondary)
				.frame(width: 16)
			Text(command.title)
				.font(.system(size: 13))
				.foregroundStyle(Theme.textPrimary)
			Spacer()
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 7)
		.background(isSelected ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
		.onHover { hovering in
			isHovering = hovering
		}
	}
}
