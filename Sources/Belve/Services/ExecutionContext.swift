import Foundation

/// Unified execution context — encapsulates "where commands run".
/// All file operations, directory listing, and command execution go through this.
enum ExecutionContext: Codable, Hashable {
	case local
	case ssh(host: String)
	case devContainer(host: String, workspacePath: String)

	struct SearchMatch {
		let path: String
		let lineNumber: Int?
		let snippet: String?
		let matchedFilename: Bool
	}

	struct DefinitionMatch {
		let path: String
		let lineNumber: Int?
		let column: Int?
	}

	private struct CommandResult {
		let output: String
		let status: Int32
	}

	/// Execute a shell command and return stdout.
	func run(_ command: String) -> String? {
		guard let result = execute(command) else { return nil }
		if result.status != 0 { return nil }
		return result.output
	}

	/// Execute a shell command and return stdout even on non-zero exit.
	private func runAllowFailure(_ command: String) -> String? {
		execute(command)?.output
	}

	// MARK: - Git

	/// Get current branch name.
	func gitBranch(_ path: String) -> String? {
		run("cd \(shellQuote(path)) && git rev-parse --abbrev-ref HEAD 2>/dev/null")?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Get git status --porcelain for file-level change markers.
	func gitStatus(_ path: String) -> [String: String] {
		guard let output = run("cd \(shellQuote(path)) && git status --porcelain 2>/dev/null") else { return [:] }
		var result: [String: String] = [:]
		for line in output.components(separatedBy: "\n") where line.count >= 4 {
			let status = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
			let file = String(line.dropFirst(3))
			result[file] = status
		}
		return result
	}

	/// Get git diff for line-level change markers (added/modified/deleted line ranges).
	struct GitDiffHunk {
		let oldStart: Int
		let oldCount: Int
		let newStart: Int
		let newCount: Int
	}

	func gitDiffHunks(_ path: String, file: String) -> [GitDiffHunk] {
		guard let output = run("cd \(shellQuote(path)) && git diff -U0 -- \(shellQuote(file)) 2>/dev/null") else { return [] }
		var hunks: [GitDiffHunk] = []
		for line in output.components(separatedBy: "\n") where line.hasPrefix("@@") {
			// Parse @@ -oldStart,oldCount +newStart,newCount @@
			let parts = line.components(separatedBy: " ")
			guard parts.count >= 3 else { continue }
			let oldPart = parts[1].dropFirst() // remove "-"
			let newPart = parts[2].dropFirst() // remove "+"
			func parseRange(_ s: Substring) -> (Int, Int) {
				let comps = s.split(separator: ",")
				let start = Int(comps[0]) ?? 0
				let count = comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
				return (start, count)
			}
			let (os, oc) = parseRange(oldPart)
			let (ns, nc) = parseRange(newPart)
			hunks.append(GitDiffHunk(oldStart: os, oldCount: oc, newStart: ns, newCount: nc))
		}
		return hunks
	}

	/// Check which paths are ignored by .gitignore. Returns set of ignored paths.
	func gitCheckIgnore(_ repoPath: String, paths: [String]) -> Set<String> {
		guard !paths.isEmpty else { return [] }
		let quotedPaths = paths.map { shellQuote($0) }.joined(separator: " ")
		// git check-ignore returns ignored paths (one per line), exit 1 if none ignored
		guard let output = runAllowFailure("cd \(shellQuote(repoPath)) && git check-ignore \(quotedPaths) 2>/dev/null") else { return [] }
		return Set(output.components(separatedBy: "\n").filter { !$0.isEmpty })
	}

	/// Execute a shell command and return stdout + exit status.
	private func execute(_ command: String) -> CommandResult? {
		let process = Process()
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		switch self {
		case .local:
			process.executableURL = URL(fileURLWithPath: "/bin/sh")
			process.arguments = ["-c", command]
		case .ssh(let host):
			process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
			process.arguments = sshArgs(host: host) + [command]
		case .devContainer(let host, let workspacePath):
			process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
			process.arguments = sshArgs(host: host) + [
				"cd \(workspacePath) && devcontainer exec --workspace-folder . sh -c '\(command.replacingOccurrences(of: "'", with: "'\\''"))'"
			]
		}

		NSLog("[Belve] ExecutionContext.run: \(process.executableURL?.path ?? "?") \(process.arguments ?? [])")

		do {
			try process.run()
			process.waitUntilExit()
		} catch {
			NSLog("[Belve] ExecutionContext.run failed: \(error)")
			return nil
		}

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
		NSLog("[Belve] ExecutionContext.run result: \(output.prefix(100)) (rc=\(process.terminationStatus))")
		return CommandResult(output: output, status: process.terminationStatus)
	}

	/// List directory contents.
	func listDirectory(_ path: String) -> [FileItem] {
		switch self {
		case .local:
			return listDirectoryLocal(path)
		default:
			return listDirectoryRemote(path)
		}
	}

	private func listDirectoryLocal(_ path: String) -> [FileItem] {
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
		return entries
			.filter { !AppConfig.shared.shouldExclude($0) }
			.sorted { a, b in
				// Dotfiles after regular files
				let aDot = a.hasPrefix(".")
				let bDot = b.hasPrefix(".")
				if aDot != bDot { return !aDot }
				return a.localizedStandardCompare(b) == .orderedAscending
			}
			.map { name in
				let fullPath = (path as NSString).appendingPathComponent(name)
				var isDir: ObjCBool = false
				fm.fileExists(atPath: fullPath, isDirectory: &isDir)
				return FileItem(name: name, path: fullPath, isDirectory: isDir.boolValue)
			}
	}

	private func listDirectoryRemote(_ path: String) -> [FileItem] {
		guard let output = run("ls -1aF \(shellQuote(path))") else { return [] }
		return output.components(separatedBy: "\n")
			.filter { !$0.isEmpty && $0 != "./" && $0 != "../" }
			.filter { entry in
				let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry.replacingOccurrences(of: "*", with: "")
				return !AppConfig.shared.shouldExclude(name)
			}
			.sorted { a, b in
				let aDot = a.hasPrefix(".")
				let bDot = b.hasPrefix(".")
				if aDot != bDot { return !aDot }
				return a.localizedStandardCompare(b) == .orderedAscending
			}
			.compactMap { entry in
				let isDir = entry.hasSuffix("/")
				let name = isDir ? String(entry.dropLast()) : entry.replacingOccurrences(of: "*", with: "")
				let fullPath = (path as NSString).appendingPathComponent(name)
				return FileItem(name: name, path: fullPath, isDirectory: isDir)
			}
	}

	/// Check if a file exists.
	func fileExists(_ path: String) -> Bool {
		switch self {
		case .local:
			return FileManager.default.fileExists(atPath: path)
		default:
			return run("test -f \(shellQuote(path)) && echo yes || echo no") == "yes"
		}
	}

	/// Read file contents.
	func readFile(_ path: String) -> String? {
		switch self {
		case .local:
			return try? String(contentsOfFile: path, encoding: .utf8)
		default:
			return run("cat \(shellQuote(path))")
		}
	}

	/// Write file contents.
	func writeFile(_ path: String, content: String) -> Bool {
		// For local, use FileManager. For remote, use heredoc.
		switch self {
		case .local:
			do {
				try content.write(toFile: path, atomically: true, encoding: .utf8)
				return true
			} catch {
				return false
			}
		default:
			let escaped = content.replacingOccurrences(of: "'", with: "'\\''")
			return run("printf '%s' '\(escaped)' > \(shellQuote(path))") != nil
		}
	}

	/// Delete a file or directory. Returns (success, trashedURL for undo on local).
	func deleteItem(_ path: String) -> (success: Bool, trashedURL: URL?) {
		switch self {
		case .local:
			var trashedURL: NSURL?
			do {
				try FileManager.default.trashItem(
					at: URL(fileURLWithPath: path),
					resultingItemURL: &trashedURL
				)
				return (true, trashedURL as URL?)
			} catch {
				NSLog("[Belve] deleteItem failed: \(error)")
				return (false, nil)
			}
		default:
			// Remote: move to .belve-trash with timestamp to avoid collisions
			let filename = (path as NSString).lastPathComponent
			let timestamp = Int(Date().timeIntervalSince1970)
			let trashName = "\(filename).\(timestamp)"
			let trashDir = "~/.belve-trash"
			let trashPath = "\(trashDir)/\(trashName)"
			let mkdirAndMove = "mkdir -p \(trashDir) && mv \(shellQuote(path)) \(shellQuote(trashPath))"
			let result = run(mkdirAndMove)
			if result != nil {
				// Encode trash path in a pseudo-URL for undo
				let pseudoURL = URL(string: "belve-remote://trash")!
				// Store the actual path in fragment to avoid URL path normalization
				let urlWithFragment = URL(string: "belve-remote://trash#\(trashPath.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? trashPath)")!
				return (true, urlWithFragment)
			}
			return (false, nil)
		}
	}

	/// Move/rename a file or directory.
	func moveItem(from: String, to: String) -> Bool {
		switch self {
		case .local:
			do {
				try FileManager.default.moveItem(atPath: from, toPath: to)
				return true
			} catch {
				NSLog("[Belve] moveItem failed: \(error)")
				return false
			}
		default:
			return run("mv \(shellQuote(from)) \(shellQuote(to))") != nil
		}
	}

	/// Create an empty file.
	func createFile(_ path: String) -> Bool {
		switch self {
		case .local:
			return FileManager.default.createFile(atPath: path, contents: nil)
		default:
			return run("touch \(shellQuote(path))") != nil
		}
	}

	func searchFileNames(rootPath: String, query: String, limit: Int = 80) -> [SearchMatch] {
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return [] }
		if let matches = searchFileNamesWithRipgrep(rootPath: rootPath, query: trimmed, limit: limit) {
			return matches
		}
		return []
	}

	func searchFileContents(rootPath: String, query: String, limit: Int = 80, excludingPaths: Set<String> = []) -> [SearchMatch] {
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return [] }
		if let matches = searchFileContentsWithRipgrep(
			rootPath: rootPath,
			query: trimmed,
			limit: limit,
			excludingPaths: excludingPaths
		) {
			return matches
		}
		return []
	}

	func resolveDefinition(
		rootPath: String,
		filePath: String,
		symbol: String,
		language: String,
		line: Int,
		column: Int
	) -> DefinitionMatch? {
		let trimmedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedSymbol.isEmpty else { return nil }

		if let sameFileMatch = resolveDefinitionInCurrentFile(
			filePath: filePath,
			symbol: trimmedSymbol,
			language: language,
			line: line
		) {
			return sameFileMatch
		}

		return resolveDefinitionWithRipgrep(
			rootPath: rootPath,
			symbol: trimmedSymbol,
			language: language
		)
	}

	/// The home/default directory for this context.
	var homeDirectory: String {
		switch self {
		case .local: return NSHomeDirectory()
		case .ssh: return "~"
		case .devContainer: return "."  // devcontainer exec starts in workspace dir
		}
	}

	/// Whether this is a remote context.
	var isRemote: Bool {
		switch self {
		case .local: return false
		case .ssh, .devContainer: return true
		}
	}

	/// The SSH host, if applicable.
	var sshHost: String? {
		switch self {
		case .local: return nil
		case .ssh(let host): return host
		case .devContainer(let host, _): return host
		}
	}

	// MARK: - Private

	/// Control socket path for SSH multiplexing (per host).
	private static func controlPath(for host: String) -> String {
		let dir = "/tmp/belve-ssh"
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		return "\(dir)/\(host)"
	}

	private func sshArgs(host: String) -> [String] {
		let cp = Self.controlPath(for: host)
		return [
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=5",
			"-o", "BatchMode=yes",
			"-o", "ControlMaster=auto",
			"-o", "ControlPath=\(cp)",
			"-o", "ControlPersist=600",
			host,
		]
	}

	private func searchFileNamesWithRipgrep(rootPath: String, query: String, limit: Int) -> [SearchMatch]? {
		let quotedRoot = shellQuote(rootPath)
		let quotedQuery = shellQuote(query)
		let filenameCommand = """
		cd \(quotedRoot) 2>/dev/null && command -v rg >/dev/null 2>&1 && rg --files | rg -i --fixed-strings -- \(quotedQuery) | head -n \(limit)
		"""
		guard let filenameOutput = run(filenameCommand) else { return nil }

		var results: [SearchMatch] = []
		for relativePath in filenameOutput.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
			let fullPath = resolveSearchPath(relativePath, rootPath: rootPath)
			results.append(
				SearchMatch(
					path: fullPath,
					lineNumber: nil,
					snippet: nil,
					matchedFilename: true
				)
			)
		}
		return results
	}

	private func searchFileContentsWithRipgrep(
		rootPath: String,
		query: String,
		limit: Int,
		excludingPaths: Set<String>
	) -> [SearchMatch]? {
		let quotedRoot = shellQuote(rootPath)
		let quotedQuery = shellQuote(query)
		let contentCommand = """
		cd \(quotedRoot) 2>/dev/null && command -v rg >/dev/null 2>&1 && rg -n -i --fixed-strings --color never -m 1 -- \(quotedQuery) . | head -n \(limit * 2)
		"""
		guard let contentOutput = run(contentCommand) else { return nil }

		var results: [SearchMatch] = []
		var seenPaths = excludingPaths

		for line in contentOutput.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
			let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
			guard parts.count >= 3 else { continue }
			let rawPath = String(parts[0])
			let normalizedPath = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
			let fullPath = resolveSearchPath(normalizedPath, rootPath: rootPath)
			guard !seenPaths.contains(fullPath) else { continue }
			guard let lineNumber = Int(parts[1]) else { continue }
			let snippet = String(parts[2]).trimmingCharacters(in: .whitespaces)
			results.append(
				SearchMatch(
					path: fullPath,
					lineNumber: lineNumber,
					snippet: snippet,
					matchedFilename: false
				)
			)
			seenPaths.insert(fullPath)
			if results.count >= limit {
				break
			}
		}

		return results
	}

	private func resolveSearchPath(_ path: String, rootPath: String) -> String {
		if path.hasPrefix("/") {
			return path
		}
		if rootPath == "." {
			return path
		}
		return (rootPath as NSString).appendingPathComponent(path)
	}

	private func shellQuote(_ path: String) -> String {
		// Handle ~ expansion: keep ~ prefix unquoted, quote the rest
		if path.hasPrefix("~/") {
			let rest = String(path.dropFirst(2))
			return "~/" + "'\(rest.replacingOccurrences(of: "'", with: "'\\''"))'"
		}
		if path == "~" { return "~" }
		if path == "." { return "." }
		return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
	}

	private func resolveDefinitionInCurrentFile(
		filePath: String,
		symbol: String,
		language: String,
		line: Int
	) -> DefinitionMatch? {
		guard let content = readFile(filePath) else { return nil }
		let lines = content.components(separatedBy: .newlines)
		guard !lines.isEmpty else { return nil }

		let searchEnd = min(max(line - 1, 0), lines.count - 1)
		let patterns = localDefinitionPatterns(for: symbol, language: language)

		for lineIndex in stride(from: searchEnd, through: 0, by: -1) {
			let text = lines[lineIndex]
			for regex in patterns {
				if let match = text.range(of: regex, options: .regularExpression) {
					let prefix = text[..<match.upperBound]
					let column = max(prefix.count - symbol.count + 1, 1)
					return DefinitionMatch(
						path: filePath,
						lineNumber: lineIndex + 1,
						column: column
					)
				}
			}
		}

		return nil
	}

	private func resolveDefinitionWithRipgrep(
		rootPath: String,
		symbol: String,
		language: String
	) -> DefinitionMatch? {
		let patterns = projectDefinitionPatterns(for: symbol, language: language)
		guard !patterns.isEmpty else { return nil }

		let exclusions = [
			"!node_modules",
			"!.git",
			"!.build",
			"!dist",
			"!build"
		]
			.map { "-g \($0)" }
			.joined(separator: " ")

		let patternArgs = patterns
			.map { "-e \(shellQuote($0))" }
			.joined(separator: " ")

		let command = """
		cd \(shellQuote(rootPath)) 2>/dev/null && command -v rg >/dev/null 2>&1 && rg -n --color never \(exclusions) \(patternArgs) .
		"""

		guard let output = run(command) else { return nil }

		for line in output.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
			let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
			guard parts.count >= 3 else { continue }
			let rawPath = String(parts[0]).replacingOccurrences(of: "./", with: "")
			guard let lineNumber = Int(parts[1]) else { continue }
			let snippet = String(parts[2])
			let fullPath = resolveSearchPath(rawPath, rootPath: rootPath)
			return DefinitionMatch(
				path: fullPath,
				lineNumber: lineNumber,
				column: definitionColumn(in: snippet, symbol: symbol)
			)
		}

		return nil
	}

	private func localDefinitionPatterns(for symbol: String, language: String) -> [String] {
		let escaped = regexQuote(symbol)
		switch language {
		case "python":
			return [
				#"^\s*(async\s+def|def)\s+\#(escaped)\b"#,
				#"^\s*class\s+\#(escaped)\b"#,
				#"^\s*\#(escaped)\s*="#
			]
		case "javascript", "jsx", "typescript", "tsx":
			return [
				#"^\s*(export\s+)?(async\s+)?function\s+\#(escaped)\b"#,
				#"^\s*(export\s+)?class\s+\#(escaped)\b"#,
				#"^\s*(export\s+)?interface\s+\#(escaped)\b"#,
				#"^\s*(export\s+)?type\s+\#(escaped)\b"#,
				#"^\s*(export\s+)?(const|let|var)\s+\#(escaped)\b"#,
				#"^\s*\#(escaped)\s*="#
			]
		default:
			return [#"^\s*\#(escaped)\s*="#]
		}
	}

	private func projectDefinitionPatterns(for symbol: String, language: String) -> [String] {
		let escaped = regexQuote(symbol)
		switch language {
		case "python":
			return [
				#"^\s*(async\s+def|def)\s+\#(escaped)\b"#,
				#"^\s*class\s+\#(escaped)\b"#
			]
		case "javascript", "jsx", "typescript", "tsx":
			return [
				#"^\s*(export\s+)?(async\s+)?function\s+\#(escaped)\b"#,
				#"^\s*(export\s+)?class\s+\#(escaped)\b"#,
				#"^\s*(export\s+)?interface\s+\#(escaped)\b"#,
				#"^\s*(export\s+)?type\s+\#(escaped)\b"#,
				#"^\s*(export\s+)?(const|let|var)\s+\#(escaped)\b"#
			]
		default:
			return []
		}
	}

	private func definitionColumn(in line: String, symbol: String) -> Int? {
		guard let range = line.range(of: symbol) else { return nil }
		return line.distance(from: line.startIndex, to: range.lowerBound) + 1
	}

	private func regexQuote(_ text: String) -> String {
		NSRegularExpression.escapedPattern(for: text)
	}
}
