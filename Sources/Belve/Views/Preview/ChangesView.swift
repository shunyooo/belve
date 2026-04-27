import SwiftUI

enum DiffMode: String, CaseIterable {
	case working = "Working"
	case staged = "Staged"
	case branch = "Branch"
	case lastCommit = "Last Commit"

	var gitArgs: [String] {
		switch self {
		case .working: return [] // uses git status --porcelain
		case .staged: return ["--staged"]
		case .branch: return ["main...HEAD"]
		case .lastCommit: return ["HEAD~1..HEAD"]
		}
	}

	var diffArgs: [String] {
		switch self {
		case .working: return ["HEAD"]
		case .staged: return ["--staged"]
		case .branch: return ["main...HEAD"]
		case .lastCommit: return ["HEAD~1..HEAD"]
		}
	}
}

struct ChangedFile: Identifiable, Hashable {
	let id = UUID()
	let status: String
	let path: String
	var filename: String { (path as NSString).lastPathComponent }
	var directory: String {
		let dir = (path as NSString).deletingLastPathComponent
		return dir.isEmpty ? "" : dir
	}

	var statusColor: Color {
		switch status {
		case "M", "MM": return Theme.yellow
		case "A", "??": return Theme.green
		case "D": return Theme.red
		case "R": return Theme.accent
		default: return Theme.textTertiary
		}
	}

	var statusLabel: String {
		switch status {
		case "??": return "U"
		default: return status
		}
	}
}

struct ChangesView: View {
	let project: Project
	@State private var diffMode: DiffMode = .working
	@State private var changedFiles: [ChangedFile] = []
	@State private var selectedFile: ChangedFile?
	@State private var diffText: String = ""
	@State private var isLoading = false
	@State private var collapsedDirs: Set<String> = []

	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack(spacing: 8) {
				Picker("", selection: $diffMode) {
					ForEach(DiffMode.allCases, id: \.self) { mode in
						Text(mode.rawValue).tag(mode)
					}
				}
				.pickerStyle(.menu)
				.frame(width: 120)

				Text("\(changedFiles.count) files changed")
					.font(.system(size: 11))
					.foregroundStyle(Theme.textSecondary)

				Spacer()

				Button {
					loadChangedFiles()
				} label: {
					Image(systemName: "arrow.clockwise")
						.font(.system(size: 11))
						.foregroundStyle(Theme.textTertiary)
				}
				.buttonStyle(.plain)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.background(Theme.bg)

			Theme.borderSubtle.frame(height: 1)

			// Content
			HStack(spacing: 0) {
				// File tree
				ScrollView {
					VStack(alignment: .leading, spacing: 0) {
						fileTree
					}
					.padding(.vertical, 4)
				}
				.frame(width: 220)
				.background(Theme.bg)

				Theme.borderSubtle.frame(width: 1)

				// Diff content
				if let file = selectedFile {
					DiffContentView(diffText: diffText, filename: file.path)
				} else {
					VStack(spacing: 8) {
						Image(systemName: "doc.text.magnifyingglass")
							.font(.system(size: 28, weight: .thin))
							.foregroundStyle(Theme.textTertiary)
						Text("Select a file to view changes")
							.font(Theme.fontBody)
							.foregroundStyle(Theme.textTertiary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(Theme.surface)
				}
			}
		}
		.onAppear { loadChangedFiles() }
		.onChange(of: diffMode) { loadChangedFiles() }
	}

	// MARK: - File Tree (PR Changes style)

	private var fileTree: some View {
		let grouped = Dictionary(grouping: changedFiles, by: { $0.directory })
		let sortedDirs = grouped.keys.sorted()

		return ForEach(sortedDirs, id: \.self) { dir in
			let files = grouped[dir] ?? []
			if dir.isEmpty {
				// Root-level files
				ForEach(files) { file in
					fileRow(file)
				}
			} else {
				// Directory group
				let isCollapsed = collapsedDirs.contains(dir)
				Button {
					if isCollapsed {
						collapsedDirs.remove(dir)
					} else {
						collapsedDirs.insert(dir)
					}
				} label: {
					HStack(spacing: 4) {
						Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
							.font(.system(size: 8, weight: .semibold))
							.foregroundStyle(Theme.textTertiary)
						Image(systemName: "folder")
							.font(.system(size: 10))
							.foregroundStyle(Theme.textTertiary)
						Text(dir)
							.font(.system(size: 11))
							.foregroundStyle(Theme.textSecondary)
							.lineLimit(1)
						Spacer()
						Text("\(files.count)")
							.font(.system(size: 9))
							.foregroundStyle(Theme.textTertiary)
					}
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)

				if !isCollapsed {
					ForEach(files) { file in
						fileRow(file)
							.padding(.leading, 16)
					}
				}
			}
		}
	}

	private func fileRow(_ file: ChangedFile) -> some View {
		let isSelected = selectedFile == file
		return Button {
			selectedFile = file
			loadDiff(for: file)
		} label: {
			HStack(spacing: 6) {
				Text(file.statusLabel)
					.font(.system(size: 9, weight: .bold, design: .monospaced))
					.foregroundStyle(file.statusColor)
					.frame(width: 14)
				Text(file.filename)
					.font(.system(size: 11))
					.foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
					.lineLimit(1)
				Spacer()
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 3)
			.background(
				RoundedRectangle(cornerRadius: 4)
					.fill(isSelected ? Theme.surfaceActive : Color.clear)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	// MARK: - Data Loading

	private func loadChangedFiles() {
		isLoading = true
		let provider = project.provider
		let rootPath = project.effectivePath
		let args = diffMode.gitArgs
		DispatchQueue.global(qos: .userInitiated).async {
			let files = provider.gitChangedFiles(rootPath, args: args)
			let changed = files.map { ChangedFile(status: $0.status, path: $0.file) }
			DispatchQueue.main.async {
				changedFiles = changed
				isLoading = false
				if let first = changed.first {
					selectedFile = first
					loadDiff(for: first)
				} else {
					selectedFile = nil
					diffText = ""
				}
			}
		}
	}

	private func loadDiff(for file: ChangedFile) {
		let provider = project.provider
		let rootPath = project.effectivePath
		let args = diffMode.diffArgs
		DispatchQueue.global(qos: .userInitiated).async {
			var diff: String?
			if file.status == "??" {
				// Untracked file — show full content as addition
				if let content = provider.readFile(
					(rootPath as NSString).appendingPathComponent(file.path)
				) {
					let lines = content.components(separatedBy: "\n")
					var result = "--- /dev/null\n+++ b/\(file.path)\n@@ -0,0 +1,\(lines.count) @@\n"
					for line in lines {
						result += "+\(line)\n"
					}
					diff = result
				}
			} else {
				diff = provider.gitFullDiff(rootPath, file: file.path, args: args)
			}
			DispatchQueue.main.async {
				diffText = diff ?? "No changes"
			}
		}
	}
}
