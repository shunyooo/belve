import SwiftUI
import WebKit

enum DiffMode: String, CaseIterable {
	case working = "Working"
	case staged = "Staged"
	case branch = "Branch"
	case lastCommit = "Last Commit"

	var gitArgs: [String] {
		switch self {
		case .working: return []
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

struct ChangedFile {
	let status: String
	let path: String
	var diff: String = ""

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
		status == "??" ? "U" : status
	}
}

struct ChangesView: View {
	let project: Project
	@State private var diffMode: DiffMode = .working
	@State private var changedFiles: [ChangedFile] = []
	@State private var isLoading = false
	@State private var totalAdded = 0
	@State private var totalRemoved = 0
	@State private var selectedFilePath: String?
	@State private var collapsedDirs: Set<String> = []
	@State private var diffWebView: WKWebView?

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

				if isLoading {
					ProgressView()
						.controlSize(.small)
						.scaleEffect(0.7)
				} else {
					Text("\(changedFiles.count) files changed")
						.font(.system(size: 11))
						.foregroundStyle(Theme.textSecondary)
					if totalAdded > 0 {
						Text("+\(totalAdded)")
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(Theme.green)
					}
					if totalRemoved > 0 {
						Text("-\(totalRemoved)")
							.font(.system(size: 11, weight: .medium))
							.foregroundStyle(Theme.red)
					}
				}

				Spacer()

				Button {
					loadAll()
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

			// Left: file tree + Right: all diffs in one scroll
			if changedFiles.isEmpty && !isLoading {
				VStack(spacing: 8) {
					Image(systemName: "checkmark.circle")
						.font(.system(size: 28, weight: .thin))
						.foregroundStyle(Theme.green)
					Text("No changes")
						.font(Theme.fontBody)
						.foregroundStyle(Theme.textTertiary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Theme.surface)
			} else {
				HStack(spacing: 0) {
					// File tree (left)
					ScrollView {
						VStack(alignment: .leading, spacing: 0) {
							fileTree
						}
						.padding(.vertical, 4)
					}
					.frame(width: 220)
					.background(Theme.bg)

					Theme.borderSubtle.frame(width: 1)

					// Unified diff (right)
					UnifiedDiffWebView(files: changedFiles, onWebViewReady: { wv in
						diffWebView = wv
					})
				}
			}
		}
		.onAppear { loadAll() }
		.onChange(of: diffMode) { loadAll() }
	}

	// MARK: - File Tree

	private var fileTree: some View {
		let grouped = Dictionary(grouping: changedFiles, by: { $0.directory })
		let sortedDirs = grouped.keys.sorted()

		return ForEach(sortedDirs, id: \.self) { dir in
			let files = grouped[dir] ?? []
			if dir.isEmpty {
				ForEach(Array(files.enumerated()), id: \.element.path) { _, file in
					fileRow(file)
				}
			} else {
				let isCollapsed = collapsedDirs.contains(dir)
				Button {
					if isCollapsed { collapsedDirs.remove(dir) } else { collapsedDirs.insert(dir) }
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
					ForEach(Array(files.enumerated()), id: \.element.path) { _, file in
						fileRow(file)
							.padding(.leading, 16)
					}
				}
			}
		}
	}

	private func fileRow(_ file: ChangedFile) -> some View {
		let isSelected = selectedFilePath == file.path
		return Button {
			selectedFilePath = file.path
			scrollToFile(file.path)
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

	private func scrollToFile(_ path: String) {
		let escaped = path.replacingOccurrences(of: "'", with: "\\'")
		diffWebView?.evaluateJavaScript(
			"document.getElementById('file-\(escaped)')?.scrollIntoView({behavior:'smooth',block:'start'})",
			completionHandler: nil
		)
	}

	private func loadAll() {
		isLoading = true
		let provider = project.provider
		let rootPath = project.effectivePath
		let listArgs = diffMode.gitArgs
		let diffArgs = diffMode.diffArgs

		DispatchQueue.global(qos: .userInitiated).async {
			let fileList = provider.gitChangedFiles(rootPath, args: listArgs)
			var files: [ChangedFile] = []
			var added = 0
			var removed = 0

			for (status, path) in fileList {
				var diff = ""
				if status == "??" {
					if let content = provider.readFile(
						rootPath == "." ? path : (rootPath as NSString).appendingPathComponent(path)
					) {
						let lines = content.components(separatedBy: "\n")
						diff = "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+\($0)" }.joined(separator: "\n")
						added += lines.count
					}
				} else {
					diff = provider.gitFullDiff(rootPath, file: path, args: diffArgs) ?? ""
					for line in diff.components(separatedBy: "\n") {
						if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
						if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
					}
				}
				files.append(ChangedFile(status: status, path: path, diff: diff))
			}

			DispatchQueue.main.async {
				changedFiles = files
				totalAdded = added
				totalRemoved = removed
				isLoading = false
			}
		}
	}
}

// MARK: - Unified Diff WebView (all files in one scroll)

private struct UnifiedDiffWebView: NSViewRepresentable {
	let files: [ChangedFile]
	var onWebViewReady: ((WKWebView) -> Void)?

	func makeNSView(context: Context) -> WKWebView {
		let webView = WKWebView()
		webView.setValue(false, forKey: "drawsBackground")
		loadHTML(webView)
		onWebViewReady?(webView)
		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
		loadHTML(nsView)
		onWebViewReady?(nsView)
	}

	private func loadHTML(_ webView: WKWebView) {
		webView.loadHTMLString(buildHTML(), baseURL: nil)
	}

	private func buildHTML() -> String {
		var sections = ""
		for file in files {
			sections += buildFileSection(file)
		}

		return """
		<!DOCTYPE html>
		<html>
		<head>
		<meta charset="UTF-8">
		<style>
		* { margin: 0; padding: 0; box-sizing: border-box; }
		body {
			background: #141418;
			color: #cdd6f4;
			font-family: -apple-system, BlinkMacSystemFont, sans-serif;
			font-size: 13px;
		}
		.file-section {
			margin-bottom: 16px;
			border: 1px solid #313244;
			border-radius: 8px;
			overflow: hidden;
			background: #1e1e2e;
		}
		.file-section:last-child {
			margin-bottom: 24px;
		}
		.file-header {
			display: flex;
			align-items: center;
			gap: 8px;
			padding: 10px 14px;
			background: #252534;
			border-bottom: 1px solid #313244;
			cursor: pointer;
			-webkit-user-select: none;
			user-select: none;
			position: sticky;
			top: 0;
			z-index: 10;
		}
		.file-header:hover {
			background: #2a2a38;
		}
		.chevron {
			font-size: 10px;
			color: #585b70;
			transition: transform 0.15s;
			width: 12px;
		}
		.chevron.collapsed {
			transform: rotate(-90deg);
		}
		.status-badge {
			font-family: 'SF Mono', Menlo, monospace;
			font-size: 10px;
			font-weight: 700;
			padding: 1px 4px;
			border-radius: 3px;
		}
		.status-M { color: #f9e2af; background: rgba(249, 226, 175, 0.15); }
		.status-A, .status-U { color: #a6e3a1; background: rgba(166, 227, 161, 0.15); }
		.status-D { color: #f38ba8; background: rgba(243, 139, 168, 0.15); }
		.status-R { color: #89b4fa; background: rgba(137, 180, 250, 0.15); }
		.filename {
			font-size: 12px;
			font-weight: 500;
			color: #cdd6f4;
		}
		.filepath {
			font-size: 11px;
			color: #585b70;
			margin-left: auto;
		}
		.diff-table {
			width: 100%;
			border-collapse: collapse;
			font-family: 'SF Mono', Menlo, Monaco, monospace;
			font-size: 12px;
			line-height: 1.5;
		}
		.diff-table tr.add { background: rgba(166, 227, 161, 0.10); }
		.diff-table tr.del { background: rgba(243, 139, 168, 0.10); }
		.diff-table tr.hunk {
			background: rgba(137, 180, 250, 0.06);
		}
		.diff-table td.ln {
			width: 40px;
			min-width: 40px;
			text-align: right;
			padding: 0 6px;
			color: #45475a;
			-webkit-user-select: none;
			user-select: none;
			border-right: 1px solid #252530;
			font-size: 11px;
		}
		.diff-table td.code {
			padding: 0 12px;
			white-space: pre-wrap;
			word-break: break-all;
		}
		.diff-table tr.add td.code { color: #a6e3a1; }
		.diff-table tr.del td.code { color: #f38ba8; }
		.diff-table tr.hunk td.code { color: #89b4fa; font-size: 11px; }
		.diff-body { overflow: hidden; transition: max-height 0.2s ease; }
		.diff-body.collapsed { max-height: 0 !important; }
		.empty-diff {
			padding: 16px;
			color: #585b70;
			font-style: italic;
			text-align: center;
		}
		</style>
		</head>
		<body>
		<div style="padding: 12px;">
		\(sections)
		</div>
		<script>
		document.querySelectorAll('.file-header').forEach(function(hdr) {
			hdr.addEventListener('click', function() {
				var body = hdr.nextElementSibling;
				var chevron = hdr.querySelector('.chevron');
				body.classList.toggle('collapsed');
				chevron.classList.toggle('collapsed');
			});
		});
		</script>
		</body>
		</html>
		"""
	}

	private func buildFileSection(_ file: ChangedFile) -> String {
		let filename = (file.path as NSString).lastPathComponent
		let dir = (file.path as NSString).deletingLastPathComponent
		let escapedFilename = escapeHTML(filename)
		let escapedDir = escapeHTML(dir.isEmpty ? "" : dir + "/")
		let statusLabel = file.status == "??" ? "U" : escapeHTML(file.status)
		let statusClass = file.status == "??" ? "U" : file.status

		let diffLines = buildDiffRows(file.diff)

		let escapedId = escapeHTML(file.path)
		return """
		<div class="file-section" id="file-\(escapedId)">
			<div class="file-header">
				<span class="chevron">▼</span>
				<span class="status-badge status-\(statusClass)">\(statusLabel)</span>
				<span class="filename">\(escapedFilename)</span>
				<span class="filepath">\(escapedDir)</span>
			</div>
			<div class="diff-body">
				\(diffLines.isEmpty ? "<div class=\"empty-diff\">No diff available</div>" : "<table class=\"diff-table\">\(diffLines)</table>")
			</div>
		</div>
		"""
	}

	private func buildDiffRows(_ diffText: String) -> String {
		let lines = diffText.components(separatedBy: "\n")
		var html = ""
		var oldLine = 0
		var newLine = 0

		for line in lines {
			let escaped = escapeHTML(line)

			if line.hasPrefix("@@") {
				let parts = line.components(separatedBy: " ")
				if parts.count >= 3 {
					let oldComps = parts[1].dropFirst().split(separator: ",")
					let newComps = parts[2].dropFirst().split(separator: ",")
					oldLine = Int(oldComps[0]) ?? 0
					newLine = Int(newComps[0]) ?? 0
				}
				html += "<tr class=\"hunk\"><td class=\"ln\"></td><td class=\"ln\"></td><td class=\"code\">\(escaped)</td></tr>"
			} else if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
				continue // skip meta lines
			} else if line.hasPrefix("+") {
				html += "<tr class=\"add\"><td class=\"ln\"></td><td class=\"ln\">\(newLine)</td><td class=\"code\">\(escaped)</td></tr>"
				newLine += 1
			} else if line.hasPrefix("-") {
				html += "<tr class=\"del\"><td class=\"ln\">\(oldLine)</td><td class=\"ln\"></td><td class=\"code\">\(escaped)</td></tr>"
				oldLine += 1
			} else if !line.isEmpty {
				html += "<tr><td class=\"ln\">\(oldLine)</td><td class=\"ln\">\(newLine)</td><td class=\"code\">\(escaped)</td></tr>"
				oldLine += 1
				newLine += 1
			}
		}
		return html
	}

	private func escapeHTML(_ s: String) -> String {
		s.replacingOccurrences(of: "&", with: "&amp;")
		 .replacingOccurrences(of: "<", with: "&lt;")
		 .replacingOccurrences(of: ">", with: "&gt;")
	}
}
