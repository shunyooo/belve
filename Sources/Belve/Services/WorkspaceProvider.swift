import Foundation

// MARK: - Protocol

/// Abstraction for workspace operations — all file, git, search, and command
/// execution goes through this. Concrete implementations handle local, SSH,
/// and DevContainer differences.
protocol WorkspaceProvider {
	// MARK: Properties
	var sshHost: String? { get }
	var effectivePath: String { get }
	var homeDirectory: String { get }
	var isRemote: Bool { get }
	/// Display label for the connection (e.g. "SSH: host", "DevContainer")
	var displayLabel: String { get }

	// MARK: Shell execution
	func run(_ command: String) -> String?

	// MARK: File operations
	func listDirectory(_ path: String) -> [FileItem]
	func fileExists(_ path: String) -> Bool
	func readFile(_ path: String) -> String?
	func writeFile(_ path: String, content: String) -> Bool
	func deleteItem(_ path: String) -> (success: Bool, trashedURL: URL?)
	func moveItem(from: String, to: String) -> Bool
	func createFile(_ path: String) -> Bool

	// MARK: Git operations
	func gitBranch(_ path: String) -> String?
	func gitStatus(_ path: String) -> [String: String]
	func gitDiffHunks(_ path: String, file: String) -> [GitDiffHunk]
	func gitCheckIgnore(_ repoPath: String, paths: [String]) -> Set<String>

	// MARK: Search
	func searchFileNames(rootPath: String, query: String, limit: Int) -> [SearchMatch]
	func searchFileContents(rootPath: String, query: String, limit: Int, excludingPaths: Set<String>) -> [SearchMatch]

	// MARK: Definition
	func resolveDefinition(rootPath: String, filePath: String, symbol: String, language: String, line: Int, column: Int) -> DefinitionMatch?

	// MARK: Launcher
	func launcherEnvironment(projectId: String, paneId: String, paneIndex: Int) -> [String: String]
}

// MARK: - Shared Types

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

struct GitDiffHunk {
	let oldStart: Int
	let oldCount: Int
	let newStart: Int
	let newCount: Int
}

// MARK: - Shared Helpers

private struct CommandResult {
	let output: String
	let status: Int32
}

private func shellQuote(_ path: String) -> String {
	if path.hasPrefix("~/") {
		let rest = String(path.dropFirst(2))
		return "~/" + "'\(rest.replacingOccurrences(of: "'", with: "'\\''"))'"
	}
	if path == "~" { return "~" }
	if path == "." { return "." }
	return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func sshControlPath(for host: String) -> String {
	let dir = "/tmp/belve-ssh"
	try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
	return "\(dir)/\(host)"
}

private func sshArgs(host: String) -> [String] {
	let cp = sshControlPath(for: host)
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

private func executeLocal(_ command: String) -> CommandResult? {
	let process = Process()
	let pipe = Pipe()
	process.standardOutput = pipe
	process.standardError = FileHandle.nullDevice
	process.executableURL = URL(fileURLWithPath: "/bin/sh")
	process.arguments = ["-c", command]

	do {
		try process.run()
		process.waitUntilExit()
	} catch {
		NSLog("[Belve] local run failed: \(error)")
		return nil
	}

	let data = pipe.fileHandleForReading.readDataToEndOfFile()
	let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
	return CommandResult(output: output, status: process.terminationStatus)
}

private func executeSSH(host: String, _ command: String) -> CommandResult? {
	let process = Process()
	let pipe = Pipe()
	process.standardOutput = pipe
	process.standardError = FileHandle.nullDevice
	process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
	process.arguments = sshArgs(host: host) + [command]

	do {
		try process.run()
		process.waitUntilExit()
	} catch {
		NSLog("[Belve] ssh run failed: \(error)")
		return nil
	}

	let data = pipe.fileHandleForReading.readDataToEndOfFile()
	let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
	return CommandResult(output: output, status: process.terminationStatus)
}

private func executeDevContainer(host: String, workspacePath: String, _ command: String) -> CommandResult? {
	let escapedCmd = command.replacingOccurrences(of: "'", with: "'\\''")
	let wrappedCmd = "cd \(workspacePath) && devcontainer exec --workspace-folder . sh -c '\(escapedCmd)'"
	return executeSSH(host: host, wrappedCmd)
}

private func regexQuote(_ text: String) -> String {
	NSRegularExpression.escapedPattern(for: text)
}

// MARK: - Default Implementations

/// Shared implementations for operations that only differ in how commands are executed.
extension WorkspaceProvider {

	// MARK: Git (shared via run())

	func gitBranch(_ path: String) -> String? {
		run("cd \(shellQuote(path)) && git rev-parse --abbrev-ref HEAD 2>/dev/null")?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

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

	func gitDiffHunks(_ path: String, file: String) -> [GitDiffHunk] {
		guard let output = run("cd \(shellQuote(path)) && git diff -U0 -- \(shellQuote(file)) 2>/dev/null") else { return [] }
		var hunks: [GitDiffHunk] = []
		for line in output.components(separatedBy: "\n") where line.hasPrefix("@@") {
			let parts = line.components(separatedBy: " ")
			guard parts.count >= 3 else { continue }
			let oldPart = parts[1].dropFirst()
			let newPart = parts[2].dropFirst()
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

	func gitCheckIgnore(_ repoPath: String, paths: [String]) -> Set<String> {
		guard !paths.isEmpty else { return [] }
		let quotedPaths = paths.map { shellQuote($0) }.joined(separator: " ")
		let result = runAllowFailure("cd \(shellQuote(repoPath)) && git check-ignore \(quotedPaths) 2>/dev/null")
		guard let output = result else { return [] }
		return Set(output.components(separatedBy: "\n").filter { !$0.isEmpty })
	}

	// MARK: Search (shared via run())

	func searchFileNames(rootPath: String, query: String, limit: Int = 80) -> [SearchMatch] {
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return [] }
		let quotedRoot = shellQuote(rootPath)
		let quotedQuery = shellQuote(trimmed)
		let command = """
		cd \(quotedRoot) 2>/dev/null && command -v rg >/dev/null 2>&1 && rg --files | rg -i --fixed-strings -- \(quotedQuery) | head -n \(limit)
		"""
		guard let output = run(command) else { return [] }
		return output.components(separatedBy: "\n")
			.filter { !$0.isEmpty }
			.map { relativePath in
				SearchMatch(
					path: resolveSearchPath(relativePath, rootPath: rootPath),
					lineNumber: nil,
					snippet: nil,
					matchedFilename: true
				)
			}
	}

	func searchFileContents(rootPath: String, query: String, limit: Int = 80, excludingPaths: Set<String> = []) -> [SearchMatch] {
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return [] }
		let quotedRoot = shellQuote(rootPath)
		let quotedQuery = shellQuote(trimmed)
		let command = """
		cd \(quotedRoot) 2>/dev/null && command -v rg >/dev/null 2>&1 && rg -n -i --fixed-strings --color never -m 1 -- \(quotedQuery) . | head -n \(limit * 2)
		"""
		guard let output = run(command) else { return [] }
		var results: [SearchMatch] = []
		var seenPaths = excludingPaths
		for line in output.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
			let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
			guard parts.count >= 3 else { continue }
			let rawPath = String(parts[0])
			let normalizedPath = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
			let fullPath = resolveSearchPath(normalizedPath, rootPath: rootPath)
			guard !seenPaths.contains(fullPath) else { continue }
			guard let lineNumber = Int(parts[1]) else { continue }
			let snippet = String(parts[2]).trimmingCharacters(in: .whitespaces)
			results.append(SearchMatch(path: fullPath, lineNumber: lineNumber, snippet: snippet, matchedFilename: false))
			seenPaths.insert(fullPath)
			if results.count >= limit { break }
		}
		return results
	}

	// MARK: Definition Resolution (shared)

	func resolveDefinition(rootPath: String, filePath: String, symbol: String, language: String, line: Int, column: Int) -> DefinitionMatch? {
		let trimmedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedSymbol.isEmpty else { return nil }
		if let m = resolveDefinitionInCurrentFile(filePath: filePath, symbol: trimmedSymbol, language: language, line: line) {
			return m
		}
		return resolveDefinitionWithRipgrep(rootPath: rootPath, symbol: trimmedSymbol, language: language)
	}

	// MARK: - Private Shared

	private func runAllowFailure(_ command: String) -> String? {
		// Subclasses override run(), this calls the underlying execute
		// We need a way to get output even on non-zero exit
		// For now, just use run() which returns nil on non-zero
		// TODO: consider adding a separate method if needed
		run(command)
	}

	private func resolveSearchPath(_ path: String, rootPath: String) -> String {
		if path.hasPrefix("/") { return path }
		if rootPath == "." { return path }
		return (rootPath as NSString).appendingPathComponent(path)
	}

	private func resolveDefinitionInCurrentFile(filePath: String, symbol: String, language: String, line: Int) -> DefinitionMatch? {
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
					let col = max(prefix.count - symbol.count + 1, 1)
					return DefinitionMatch(path: filePath, lineNumber: lineIndex + 1, column: col)
				}
			}
		}
		return nil
	}

	private func resolveDefinitionWithRipgrep(rootPath: String, symbol: String, language: String) -> DefinitionMatch? {
		let patterns = projectDefinitionPatterns(for: symbol, language: language)
		guard !patterns.isEmpty else { return nil }
		let exclusions = ["!node_modules", "!.git", "!.build", "!dist", "!build"].map { "-g \($0)" }.joined(separator: " ")
		let patternArgs = patterns.map { "-e \(shellQuote($0))" }.joined(separator: " ")
		let command = "cd \(shellQuote(rootPath)) 2>/dev/null && command -v rg >/dev/null 2>&1 && rg -n --color never \(exclusions) \(patternArgs) ."
		guard let output = run(command) else { return nil }
		for line in output.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
			let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
			guard parts.count >= 3 else { continue }
			let rawPath = String(parts[0]).replacingOccurrences(of: "./", with: "")
			guard let lineNumber = Int(parts[1]) else { continue }
			let snippet = String(parts[2])
			let fullPath = resolveSearchPath(rawPath, rootPath: rootPath)
			return DefinitionMatch(path: fullPath, lineNumber: lineNumber, column: definitionColumn(in: snippet, symbol: symbol))
		}
		return nil
	}

	private func localDefinitionPatterns(for symbol: String, language: String) -> [String] {
		let escaped = regexQuote(symbol)
		switch language {
		case "python":
			return [#"^\s*(async\s+def|def)\s+\#(escaped)\b"#, #"^\s*class\s+\#(escaped)\b"#, #"^\s*\#(escaped)\s*="#]
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
			return [#"^\s*(async\s+def|def)\s+\#(escaped)\b"#, #"^\s*class\s+\#(escaped)\b"#]
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
}

// MARK: - LocalProvider

struct LocalProvider: WorkspaceProvider {
	let path: String?

	var sshHost: String? { nil }
	var effectivePath: String { path ?? NSHomeDirectory() }
	var homeDirectory: String { NSHomeDirectory() }
	var isRemote: Bool { false }
	var displayLabel: String { "" }

	func run(_ command: String) -> String? {
		guard let result = executeLocal(command), result.status == 0 else { return nil }
		return result.output
	}

	func listDirectory(_ path: String) -> [FileItem] {
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
		return entries
			.filter { !AppConfig.shared.shouldExclude($0) }
			.sorted { a, b in
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

	func fileExists(_ path: String) -> Bool {
		FileManager.default.fileExists(atPath: path)
	}

	func readFile(_ path: String) -> String? {
		try? String(contentsOfFile: path, encoding: .utf8)
	}

	func writeFile(_ path: String, content: String) -> Bool {
		do {
			try content.write(toFile: path, atomically: true, encoding: .utf8)
			return true
		} catch { return false }
	}

	func deleteItem(_ path: String) -> (success: Bool, trashedURL: URL?) {
		var trashedURL: NSURL?
		do {
			try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashedURL)
			return (true, trashedURL as URL?)
		} catch {
			NSLog("[Belve] deleteItem failed: \(error)")
			return (false, nil)
		}
	}

	func moveItem(from: String, to: String) -> Bool {
		do {
			try FileManager.default.moveItem(atPath: from, toPath: to)
			return true
		} catch {
			NSLog("[Belve] moveItem failed: \(error)")
			return false
		}
	}

	func createFile(_ path: String) -> Bool {
		FileManager.default.createFile(atPath: path, contents: nil)
	}

	func launcherEnvironment(projectId: String, paneId: String, paneIndex: Int) -> [String: String] {
		var env: [String: String] = [
			"BELVE_PROJECT_ID": projectId,
			"BELVE_PANE_ID": paneId,
			"BELVE_PANE_INDEX": String(paneIndex),
		]
		if let p = path { env["BELVE_WORKDIR"] = p }
		return env
	}
}

// MARK: - SSHProvider

struct SSHProvider: WorkspaceProvider {
	let host: String
	let path: String?

	var sshHost: String? { host }
	var effectivePath: String { path ?? "~" }
	var homeDirectory: String { "~" }
	var isRemote: Bool { true }
	var displayLabel: String { "SSH: \(host.components(separatedBy: ".").first ?? host)" }

	func run(_ command: String) -> String? {
		guard let result = executeSSH(host: host, command), result.status == 0 else { return nil }
		return result.output
	}

	func listDirectory(_ path: String) -> [FileItem] { listDirectoryRemote(path) }
	func fileExists(_ path: String) -> Bool { run("test -f \(shellQuote(path)) && echo yes || echo no") == "yes" }
	func readFile(_ path: String) -> String? { run("cat \(shellQuote(path))") }
	func writeFile(_ path: String, content: String) -> Bool {
		let escaped = content.replacingOccurrences(of: "'", with: "'\\''")
		return run("printf '%s' '\(escaped)' > \(shellQuote(path))") != nil
	}
	func deleteItem(_ path: String) -> (success: Bool, trashedURL: URL?) { deleteItemRemote(path) }
	func moveItem(from: String, to: String) -> Bool { run("mv \(shellQuote(from)) \(shellQuote(to))") != nil }
	func createFile(_ path: String) -> Bool { run("touch \(shellQuote(path))") != nil }

	func launcherEnvironment(projectId: String, paneId: String, paneIndex: Int) -> [String: String] {
		var env: [String: String] = [
			"BELVE_SSH_HOST": host,
			"BELVE_PROJECT_ID": projectId,
			"BELVE_PANE_ID": paneId,
			"BELVE_PANE_INDEX": String(paneIndex),
		]
		if let p = path { env["BELVE_WORKDIR"] = p }
		return env
	}
}

// MARK: - DevContainerProvider

struct DevContainerProvider: WorkspaceProvider {
	let host: String
	let workspace: String

	var sshHost: String? { host }
	var effectivePath: String { "." }
	var homeDirectory: String { "." }
	var isRemote: Bool { true }
	var displayLabel: String { "DevContainer" }

	func run(_ command: String) -> String? {
		guard let result = executeDevContainer(host: host, workspacePath: workspace, command), result.status == 0 else { return nil }
		return result.output
	}

	func listDirectory(_ path: String) -> [FileItem] { listDirectoryRemote(path) }
	func fileExists(_ path: String) -> Bool { run("test -f \(shellQuote(path)) && echo yes || echo no") == "yes" }
	func readFile(_ path: String) -> String? { run("cat \(shellQuote(path))") }
	func writeFile(_ path: String, content: String) -> Bool {
		let escaped = content.replacingOccurrences(of: "'", with: "'\\''")
		return run("printf '%s' '\(escaped)' > \(shellQuote(path))") != nil
	}
	func deleteItem(_ path: String) -> (success: Bool, trashedURL: URL?) { deleteItemRemote(path) }
	func moveItem(from: String, to: String) -> Bool { run("mv \(shellQuote(from)) \(shellQuote(to))") != nil }
	func createFile(_ path: String) -> Bool { run("touch \(shellQuote(path))") != nil }

	func launcherEnvironment(projectId: String, paneId: String, paneIndex: Int) -> [String: String] {
		[
			"BELVE_SSH_HOST": host,
			"BELVE_WORKDIR": workspace,
			"BELVE_DEVCONTAINER": "1",
			"BELVE_PROJECT_ID": projectId,
			"BELVE_PANE_ID": paneId,
			"BELVE_PANE_INDEX": String(paneIndex),
		]
	}
}

// MARK: - Shared Remote Helpers

private func listDirectoryRemote(_ path: String, run: (String) -> String?) -> [FileItem] {
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

extension SSHProvider {
	fileprivate func listDirectoryRemote(_ path: String) -> [FileItem] {
		WorkspaceProvider_listDirectoryRemote(path, run: run)
	}
}

extension DevContainerProvider {
	fileprivate func listDirectoryRemote(_ path: String) -> [FileItem] {
		WorkspaceProvider_listDirectoryRemote(path, run: run)
	}
}

private func WorkspaceProvider_listDirectoryRemote(_ path: String, run: (String) -> String?) -> [FileItem] {
	Belve.listDirectoryRemote(path, run: run)
}

private func deleteItemRemote(_ path: String, run: (String) -> String?) -> (success: Bool, trashedURL: URL?) {
	let filename = (path as NSString).lastPathComponent
	let timestamp = Int(Date().timeIntervalSince1970)
	let trashName = "\(filename).\(timestamp)"
	let trashDir = "~/.belve-trash"
	let trashPath = "\(trashDir)/\(trashName)"
	let mkdirAndMove = "mkdir -p \(trashDir) && mv \(shellQuote(path)) \(shellQuote(trashPath))"
	if run(mkdirAndMove) != nil {
		let urlWithFragment = URL(string: "belve-remote://trash#\(trashPath.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? trashPath)")!
		return (true, urlWithFragment)
	}
	return (false, nil)
}

extension SSHProvider {
	fileprivate func deleteItemRemote(_ path: String) -> (success: Bool, trashedURL: URL?) {
		Belve.deleteItemRemote(path, run: run)
	}
}

extension DevContainerProvider {
	fileprivate func deleteItemRemote(_ path: String) -> (success: Bool, trashedURL: URL?) {
		Belve.deleteItemRemote(path, run: run)
	}
}
