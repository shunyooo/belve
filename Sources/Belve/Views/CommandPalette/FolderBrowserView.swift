import SwiftUI

struct FolderBrowserView: View {
	@Binding var isPresented: Bool
	let sshHost: String?
	let onSelect: (String) -> Void

	@State private var currentPath: String
	@State private var typedSuffix: String = ""
	@State private var items: [FileItem] = []
	@State private var selectedIndex: Int = 0
	@FocusState private var isFocused: Bool

	init(isPresented: Binding<Bool>, initialPath: String, sshHost: String?, onSelect: @escaping (String) -> Void) {
		self._isPresented = isPresented
		self._currentPath = State(initialValue: initialPath)
		self.sshHost = sshHost
		self.onSelect = onSelect
	}

	private var displayPath: String {
		let base = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
		return base + typedSuffix
	}

	private var filtered: [FileItem] {
		if typedSuffix.isEmpty { return items }
		return items.filter { $0.name.localizedCaseInsensitiveContains(typedSuffix) }
	}

	var body: some View {
		VStack(spacing: 0) {
			// Path field
			HStack(spacing: 8) {
				Image(systemName: "folder")
					.font(.system(size: 12))
					.foregroundStyle(Theme.textTertiary)
				TextField("", text: Binding(
					get: { displayPath },
					set: { newValue in
						handlePathInput(newValue)
					}
				))
				.textFieldStyle(.plain)
				.font(.system(size: 13, design: .monospaced))
				.foregroundStyle(Theme.textPrimary)
				.focused($isFocused)
				.onSubmit {
					// Enter always confirms current path
					isPresented = false
					onSelect(currentPath)
				}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 10)

			Theme.border
				.frame(height: 1)

			// Folder list
			ScrollView {
				VStack(spacing: 0) {
					// Parent
					if (currentPath as NSString).deletingLastPathComponent != currentPath {
						FolderBrowserRow(name: "..", icon: "arrow.up", isSelected: selectedIndex == -1)
							.onTapGesture {
								let parent = (currentPath as NSString).deletingLastPathComponent
								enterDirectory(parent)
							}
					}

					ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
						FolderBrowserRow(
							name: item.name,
							icon: item.isDirectory ? "folder" : "doc",
							isSelected: index == selectedIndex
						)
						.onTapGesture {
							if item.isDirectory {
								enterDirectory(item.path)
							}
						}
					}
				}
			}
			.frame(maxHeight: 500)
		}
		.frame(width: 500)
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
		.onKeyPress(.tab) {
			if selectedIndex >= 0, selectedIndex < filtered.count {
				let selected = filtered[selectedIndex]
				if selected.isDirectory {
					enterDirectory(selected.path)
					return .handled
				}
			}
			return .ignored
		}
		.onKeyPress(.escape) {
			isPresented = false
			return .handled
		}
		.onAppear {
			isFocused = true
			loadDirectory()
		}
	}

	private func enterDirectory(_ path: String) {
		currentPath = path
		typedSuffix = ""
		selectedIndex = 0
		loadDirectory()
	}

	private func loadDirectory() {
		DispatchQueue.global().async {
			let result = FileService.listDirectory(path: currentPath, sshHost: sshHost)
				.filter { $0.isDirectory }
			DispatchQueue.main.async {
				items = result
			}
		}
	}

	private func handlePathInput(_ newValue: String) {
		let base = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
		if newValue.hasPrefix(base) {
			let newSuffix = String(newValue.dropFirst(base.count))
			if newSuffix != typedSuffix {
				typedSuffix = newSuffix
				selectedIndex = 0
			}
		} else if newValue.hasSuffix("/") && newValue.count > 1 {
			// User typed a full path ending with /
			let newPath = String(newValue.dropLast())
			enterDirectory(newPath)
		}
	}
}

struct FolderBrowserRow: View {
	let name: String
	let icon: String
	let isSelected: Bool
	@State private var isHovering = false

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: icon)
				.font(.system(size: 11))
				.foregroundStyle(Theme.yellow)
				.frame(width: 16)
			Text(name)
				.font(.system(size: 13))
				.foregroundStyle(Theme.textPrimary)
			Spacer()
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.background(isSelected ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
		.onHover { hovering in
			isHovering = hovering
		}
	}
}
