import SwiftUI

struct FolderBrowserView: View {
	@Binding var isPresented: Bool
	let provider: any WorkspaceProvider
	/// When true, each loaded directory is scanned (remote SSH only) for
	/// `.devcontainer/devcontainer.json` children so the UI can badge them.
	var highlightDevContainers: Bool = false
	let onSelect: (String) -> Void

	@State private var currentPath: String
	@State private var typedSuffix: String = ""
	@State private var items: [FileItem] = []
	@State private var devContainerDirs: Set<String> = []
	@State private var currentPathHasDevContainer: Bool = false
	@State private var selectedIndex: Int = 0
	@State private var keyMonitor: Any? = nil
	@FocusState private var isFocused: Bool

	init(
		isPresented: Binding<Bool>,
		initialPath: String,
		provider: any WorkspaceProvider,
		highlightDevContainers: Bool = false,
		onSelect: @escaping (String) -> Void
	) {
		self._isPresented = isPresented
		self._currentPath = State(initialValue: initialPath)
		self.provider = provider
		self.highlightDevContainers = highlightDevContainers
		self.onSelect = onSelect
	}

	private var displayPath: String {
		let base = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
		return base + typedSuffix
	}

	private var filtered: [FileItem] {
		if typedSuffix.isEmpty { return items }
		let scored = items.compactMap { item -> (FileItem, Int)? in
			guard let score = fuzzyScore(query: typedSuffix, in: item.name) else { return nil }
			return (item, score)
		}
		return scored.sorted { lhs, rhs in
			// Primary: score desc, Secondary: shorter name (more specific) first
			if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
			return lhs.0.name.count < rhs.0.name.count
		}.map { $0.0 }
	}

	/// fzf-ish fuzzy matcher. Returns nil if any query character isn't found in order.
	/// Score rewards consecutive matches, matches at word boundaries, and matches near the start.
	private func fuzzyScore(query: String, in text: String) -> Int? {
		let q = Array(query.lowercased())
		let t = Array(text.lowercased())
		guard !q.isEmpty else { return 0 }
		var qi = 0
		var score = 0
		var lastMatch = -2
		for (i, c) in t.enumerated() {
			guard qi < q.count else { break }
			if c == q[qi] {
				score += 10
				if i == lastMatch + 1 { score += 8 }          // consecutive
				if i == 0 { score += 12 }                      // at start
				else if i > 0 {
					let prev = t[i - 1]
					if prev == "-" || prev == "_" || prev == "." || prev == "/" || prev == " " {
						score += 6                             // after separator
					}
				}
				lastMatch = i
				qi += 1
			}
		}
		return qi == q.count ? score : nil
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
					if highlightDevContainers && !currentPathHasDevContainer {
						NSSound.beep()
						return
					}
					isPresented = false
					onSelect(currentPath)
				}
				if highlightDevContainers {
					HStack(spacing: 3) {
						Image(systemName: "shippingbox.fill")
							.font(.system(size: 9))
						Text(currentPathHasDevContainer ? "devcontainer" : "no devcontainer")
							.font(.system(size: 10, weight: .medium))
					}
					.foregroundStyle(currentPathHasDevContainer ? Theme.accent : Theme.textTertiary)
					.padding(.horizontal, 5)
					.padding(.vertical, 1.5)
					.background(
						RoundedRectangle(cornerRadius: 3)
							.fill((currentPathHasDevContainer ? Theme.accent : Theme.textTertiary).opacity(0.15))
					)
				}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 10)

			Theme.border
				.frame(height: 1)

			// Folder list
			ScrollViewReader { proxy in
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
								isSelected: index == selectedIndex,
								hasDevContainer: devContainerDirs.contains(item.path)
							)
							.id(item.id)
							.onTapGesture {
								if item.isDirectory {
									enterDirectory(item.path)
								}
							}
						}
					}
				}
				.frame(maxHeight: 500)
				.onChange(of: selectedIndex) {
					guard selectedIndex >= 0, selectedIndex < filtered.count else { return }
					withAnimation(.easeOut(duration: 0.12)) {
						proxy.scrollTo(filtered[selectedIndex].id, anchor: .center)
					}
				}
			}
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
			loadDirectory()
			installKeyMonitor()
			// Grab focus now and again on the next runloop tick. The palette may still
			// be finishing a transition (e.g. SSH-host picker → folder browser), and a
			// same-tick @FocusState update can be dropped if the view tree is mid-swap.
			isFocused = true
			DispatchQueue.main.async { isFocused = true }
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isFocused = true }
		}
		.onDisappear {
			removeKeyMonitor()
		}
	}

	// AppKit key monitor so arrow keys / Tab / Enter work even while the TextField
	// (which normally consumes arrow keys for caret movement) has focus.
	private func installKeyMonitor() {
		guard keyMonitor == nil else { return }
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			switch event.keyCode {
			case 125:  // down
				selectedIndex = min(max(filtered.count - 1, 0), selectedIndex + 1)
				return nil
			case 126:  // up
				selectedIndex = max(0, selectedIndex - 1)
				return nil
			case 48:   // tab
				if selectedIndex >= 0, selectedIndex < filtered.count {
					let selected = filtered[selectedIndex]
					if selected.isDirectory {
						enterDirectory(selected.path)
						return nil
					}
				}
				return event
			case 36:   // return — always confirms the currently-open path.
				if highlightDevContainers && !currentPathHasDevContainer {
					// Only devcontainer dirs can be confirmed in this mode. Give feedback
					// and keep the browser open so the user can navigate elsewhere.
					NSSound.beep()
					return nil
				}
				isPresented = false
				onSelect(currentPath)
				return nil
			case 53:   // escape
				isPresented = false
				return nil
			default:
				return event
			}
		}
	}

	private func removeKeyMonitor() {
		if let keyMonitor {
			NSEvent.removeMonitor(keyMonitor)
			self.keyMonitor = nil
		}
	}

	private func enterDirectory(_ path: String) {
		currentPath = path
		typedSuffix = ""
		selectedIndex = 0
		loadDirectory()
	}

	private func loadDirectory() {
		let pathAtStart = currentPath
		DispatchQueue.global().async {
			// Remote DevContainer browser は project に bind されてない (= RPC client
			// 無し) なので、SSHProvider.listDirectory (RPC ONLY) は空を返す。
			// 直接 SSH 経由の listing を使う。
			let dirs: [FileItem]
			if highlightDevContainers, let sshProvider = provider as? SSHProvider {
				dirs = sshProvider.listDirectoryViaSSH(pathAtStart).filter { $0.isDirectory }
			} else {
				dirs = provider.listDirectory(pathAtStart).filter { $0.isDirectory }
			}

			// Second pass for DevContainer mode: batch-check which subdirs contain
			// .devcontainer/devcontainer.json, plus whether the current directory itself does.
			var dcMatches: Set<String> = []
			var currentHasDC = false
			if highlightDevContainers, let sshProvider = provider as? SSHProvider {
				dcMatches = sshProvider.findDevContainerDirs(in: dirs.map { $0.path })
				// `fileExists` は RPC ONLY なので folder browser context (=
				// RPC client 無し) では false 固定になる → 「no devcontainer」
				// 誤表示。findDevContainerDirs (= 直 SSH) で current path 自体も
				// チェックする。
				currentHasDC = !sshProvider.findDevContainerDirs(in: [pathAtStart]).isEmpty
			}

			DispatchQueue.main.async {
				guard pathAtStart == currentPath else { return }  // user navigated away mid-load
				items = dirs
				devContainerDirs = dcMatches
				currentPathHasDevContainer = currentHasDC
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
	var hasDevContainer: Bool = false
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
			if hasDevContainer {
				HStack(spacing: 3) {
					Image(systemName: "shippingbox.fill")
						.font(.system(size: 9))
					Text("devcontainer")
						.font(.system(size: 10, weight: .medium))
				}
				.foregroundStyle(Theme.accent)
				.padding(.horizontal, 5)
				.padding(.vertical, 1.5)
				.background(
					RoundedRectangle(cornerRadius: 3)
						.fill(Theme.accent.opacity(0.15))
				)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.background(isSelected ? Theme.surfaceActive : (isHovering ? Theme.surfaceHover : Color.clear))
		.onHover { hovering in
			isHovering = hovering
		}
	}
}
