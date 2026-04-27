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
	func modificationDate(_ path: String) -> Date?

	// MARK: Git operations
	func gitBranch(_ path: String) -> String?
	func gitStatus(_ path: String) -> [String: String]
	func gitDiffHunks(_ path: String, file: String) -> [GitDiffHunk]
	func gitCheckIgnore(_ repoPath: String, paths: [String]) -> Set<String>
	func gitFullDiff(_ path: String, file: String, args: [String]) -> String?
	func gitDiffBulk(_ path: String, args: [String]) -> String?
	func gitChangedFiles(_ path: String, args: [String]) -> [(status: String, file: String)]

	// MARK: Search
	func searchFileNames(rootPath: String, query: String, limit: Int) -> [SearchMatch]
	func searchFileContents(rootPath: String, query: String, limit: Int, excludingPaths: Set<String>) -> [SearchMatch]

	// MARK: Definition
	func resolveDefinition(rootPath: String, filePath: String, symbol: String, language: String, line: Int, column: Int) -> DefinitionMatch?

	// MARK: File download (binary-safe, for media preview)
	func downloadFile(remotePath: String, to localURL: URL) -> Bool

	// MARK: File upload (binary-safe, for drag-drop from Finder)
	func uploadFile(localURL: URL, to remotePath: String) -> Bool

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

/// Shared ControlPath so all Belve SSH operations (file ops, SCP, SSHTunnelManager
/// port forwards, launcher's deploy+setup) reuse one SSH ControlMaster per host.
private func sshControlPath(for host: String) -> String {
	"/tmp/belve-ssh-ctrl-\(host)"
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
	} catch {
		NSLog("[Belve] local run failed: \(error)")
		return nil
	}

	let data = pipe.fileHandleForReading.readDataToEndOfFile()
	process.waitUntilExit()
	let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
	return CommandResult(output: output, status: process.terminationStatus)
}

/// 同時 `ssh host cmd` 実行数を絞るための semaphore。RPC が一時的に死んだ時
/// (router 経由の container :19224 が旧 broker で listen してない等) に
/// provider fallback が殺到して SSH MaxSessions を食い尽くすのを防ぐ。
/// 3 並列まで。残りは順番待ち。RPC 経路に乗る steady state ではほぼ通らない。
private let executeSSHSemaphore = DispatchSemaphore(value: 3)

private func executeSSH(host: String, _ command: String) -> CommandResult? {
	executeSSHSemaphore.wait()
	defer { executeSSHSemaphore.signal() }

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
		// Try RPC first (if this provider is associated with an active
		// project that has an RPC client). For Local / providers without
		// projectId, this returns nil and we fall through.
		if let pid = (self as? RemoteProjectScoped)?.projectIdForRPC,
		   let client = RemoteRPCRegistry.shared.client(for: pid),
		   let res = syncRPC(client: client, op: "gitBranch", params: ["path": path]),
		   let result = res.result,
		   let branch = result["branch"] as? String
		{
			return branch.isEmpty ? nil : branch
		}
		return run("cd \(shellQuote(path)) && git rev-parse --abbrev-ref HEAD 2>/dev/null")?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	func gitStatus(_ path: String) -> [String: String] {
		if let pid = (self as? RemoteProjectScoped)?.projectIdForRPC,
		   let client = RemoteRPCRegistry.shared.client(for: pid),
		   let res = syncRPC(client: client, op: "gitStatus", params: ["path": path]),
		   let result = res.result,
		   let files = result["files"] as? [[String: Any]]
		{
			var out: [String: String] = [:]
			for f in files {
				guard let status = f["status"] as? String,
				      let file = f["file"] as? String
				else { continue }
				out[file] = status
			}
			return out
		}
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
		// RPC fast path
		if let pid = (self as? RemoteProjectScoped)?.projectIdForRPC,
		   let client = RemoteRPCRegistry.shared.client(for: pid),
		   let res = syncRPC(client: client, op: "gitDiff", params: ["path": path, "file": file]),
		   let result = res.result,
		   let diff = result["diff"] as? String
		{
			return Self.parseDiffHunks(diff)
		}
		guard let output = run("cd \(shellQuote(path)) && git diff -U0 -- \(shellQuote(file)) 2>/dev/null") else { return [] }
		return Self.parseDiffHunks(output)
	}

	/// Parse `git diff -U0` output into hunks. Shared between RPC + shell paths.
	private static func parseDiffHunks(_ output: String) -> [GitDiffHunk] {
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
		// RPC fast path
		if let pid = (self as? RemoteProjectScoped)?.projectIdForRPC,
		   let client = RemoteRPCRegistry.shared.client(for: pid),
		   let res = syncRPC(client: client, op: "gitCheckIgnore", params: ["path": repoPath, "paths": paths]),
		   let result = res.result,
		   let ignored = result["ignored"] as? [String]
		{
			return Set(ignored)
		}
		let quotedPaths = paths.map { shellQuote($0) }.joined(separator: " ")
		let result = runAllowFailure("cd \(shellQuote(repoPath)) && git check-ignore \(quotedPaths) 2>/dev/null")
		guard let output = result else { return [] }
		return Set(output.components(separatedBy: "\n").filter { !$0.isEmpty })
	}

	func gitFullDiff(_ path: String, file: String, args: [String]) -> String? {
		// RPC fast path
		if let pid = (self as? RemoteProjectScoped)?.projectIdForRPC,
		   let client = RemoteRPCRegistry.shared.client(for: pid) {
			var params: [String: Any] = ["path": path, "file": file]
			if !args.isEmpty { params["args"] = args }
			if let res = syncRPC(client: client, op: "gitDiff", params: params),
			   let result = res.result,
			   let diff = result["diff"] as? String {
				return diff.isEmpty ? nil : diff
			}
		}
		let quotedArgs = args.joined(separator: " ")
		let cmd = "cd \(shellQuote(path)) && git diff \(quotedArgs) -- \(shellQuote(file)) 2>/dev/null"
		return run(cmd)
	}

	/// Bulk diff for all files (single git command). Returns raw unified diff.
	func gitDiffBulk(_ path: String, args: [String]) -> String? {
		if let pid = (self as? RemoteProjectScoped)?.projectIdForRPC,
		   let client = RemoteRPCRegistry.shared.client(for: pid) {
			var params: [String: Any] = ["path": path]
			if !args.isEmpty { params["args"] = args }
			if let res = syncRPC(client: client, op: "gitDiffBulk", params: params),
			   let result = res.result,
			   let diff = result["diff"] as? String {
				return diff
			}
		}
		let quotedArgs = args.joined(separator: " ")
		return run("cd \(shellQuote(path)) && git diff \(quotedArgs) 2>/dev/null")
	}

	func gitChangedFiles(_ path: String, args: [String]) -> [(status: String, file: String)] {
		// RPC fast path
		if let pid = (self as? RemoteProjectScoped)?.projectIdForRPC,
		   let client = RemoteRPCRegistry.shared.client(for: pid) {
			var params: [String: Any] = ["path": path]
			if !args.isEmpty { params["args"] = args }
			if let res = syncRPC(client: client, op: "gitChangedFiles", params: params),
			   let result = res.result,
			   let files = result["files"] as? [[String: Any]] {
				return files.compactMap { f in
					guard let status = f["status"] as? String,
						  let file = f["file"] as? String else { return nil }
					return (status, file)
				}
			}
		}
		// Shell fallback
		let cmd: String
		if args.isEmpty {
			cmd = "cd \(shellQuote(path)) && git status --porcelain 2>/dev/null"
		} else {
			let quotedArgs = args.joined(separator: " ")
			cmd = "cd \(shellQuote(path)) && git diff \(quotedArgs) --name-status 2>/dev/null"
		}
		guard let output = run(cmd), !output.isEmpty else { return [] }
		var results: [(status: String, file: String)] = []
		for line in output.components(separatedBy: "\n") where !line.isEmpty {
			if args.isEmpty {
				guard line.count >= 4 else { continue }
				let status = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
				let file = String(line.dropFirst(3))
				results.append((status.isEmpty ? "?" : status, file))
			} else {
				let parts = line.split(separator: "\t", maxSplits: 1)
				guard parts.count == 2 else { continue }
				results.append((String(parts[0]), String(parts[1])))
			}
		}
		return results
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
		let items = entries
			.filter { !AppConfig.shared.shouldExclude($0) }
			.map { name -> FileItem in
				let fullPath = (path as NSString).appendingPathComponent(name)
				var isDir: ObjCBool = false
				fm.fileExists(atPath: fullPath, isDirectory: &isDir)
				return FileItem(name: name, path: fullPath, isDirectory: isDir.boolValue)
			}
		return items.sortedLikeVSCode()
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

	func modificationDate(_ path: String) -> Date? {
		try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
	}

	func downloadFile(remotePath: String, to localURL: URL) -> Bool {
		// Local: just copy
		let absPath: String
		if remotePath.hasPrefix("/") {
			absPath = remotePath
		} else {
			absPath = (effectivePath as NSString).appendingPathComponent(remotePath)
		}
		do {
			try? FileManager.default.removeItem(at: localURL)
			try FileManager.default.copyItem(atPath: absPath, toPath: localURL.path)
			return true
		} catch {
			NSLog("[Belve] downloadFile local failed: \(error)")
			return false
		}
	}

	func uploadFile(localURL: URL, to remotePath: String) -> Bool {
		let absDest: String
		if remotePath.hasPrefix("/") {
			absDest = remotePath
		} else {
			absDest = (effectivePath as NSString).appendingPathComponent(remotePath)
		}
		do {
			try? FileManager.default.removeItem(atPath: absDest)
			try FileManager.default.copyItem(atPath: localURL.path, toPath: absDest)
			return true
		} catch {
			NSLog("[Belve] uploadFile local failed: \(error)")
			return false
		}
	}

	func launcherEnvironment(projectId: String, paneId: String, paneIndex: Int) -> [String: String] {
		[
			"BELVE_PROJECT_ID": projectId,
			"BELVE_PANE_ID": paneId,
			"BELVE_PANE_INDEX": String(paneIndex),
			// Default to the user's home directory when the project has no path
			// set (e.g. a freshly created project) so the shell doesn't land in "/".
			"BELVE_WORKDIR": path ?? NSHomeDirectory(),
		]
	}
}

// MARK: - Remote provider scoping for RPC

/// Mixin: providers that have an associated project can hand the gitBranch /
/// gitStatus shared impls a projectId, which they use to look up the
/// `RemoteRPCClient` and shortcut around the executeSSH path. Local and
/// dummy providers don't conform → they keep using the `run(...)` shell path.
protocol RemoteProjectScoped {
	var projectIdForRPC: UUID { get }
}

extension RemoteProjectScoped {
	/// 同期 RPC 呼び出し → result を返す。Client 未確立 / エラー時は nil。
	/// 各 provider 実装が「RPC で値が取れたらそれを返す、取れなければ
	/// executeSSH 経由 fallback」のパターンで使う。
	func rpcResult(op: String, params: [String: Any]) -> [String: Any]? {
		guard let client = RemoteRPCRegistry.shared.client(for: projectIdForRPC),
		      let res = syncRPC(client: client, op: op, params: params),
		      let result = res.result
		else { return nil }
		return result
	}

	/// op が成功すれば true。result の中身は見ない (write/delete/mkdir/rename 用)。
	func rpcOK(op: String, params: [String: Any]) -> Bool {
		guard let client = RemoteRPCRegistry.shared.client(for: projectIdForRPC),
		      let res = syncRPC(client: client, op: op, params: params)
		else { return false }
		return res.ok
	}
}

// MARK: - SSHProvider

struct SSHProvider: WorkspaceProvider, RemoteProjectScoped {
	let host: String
	let path: String?
	/// 該当プロジェクト ID。`RemoteRPCRegistry` のキーに使う (RPC が利用可能
	/// なら ls/git ops を control 経由に切り替える)。
	let projectId: UUID
	var projectIdForRPC: UUID { projectId }

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

	func fileExists(_ path: String) -> Bool {
		// RPC: stat が成功したら存在。size/mtime は見ない。
		if let _ = rpcResult(op: "stat", params: ["path": path]) { return true }
		// Fallback shell
		return run("test -f \(shellQuote(path)) && echo yes || echo no") == "yes"
	}

	func readFile(_ path: String) -> String? {
		if let result = rpcResult(op: "read", params: ["path": path]),
		   let content = result["content"] as? String { return content }
		return run("cat \(shellQuote(path))")
	}

	func writeFile(_ path: String, content: String) -> Bool {
		// RPC は base64 で渡す方が改行/制御文字に安全。
		let b64 = Data(content.utf8).base64EncodedString()
		if rpcOK(op: "write", params: ["path": path, "data": b64, "encoding": "base64"]) {
			return true
		}
		let escaped = content.replacingOccurrences(of: "'", with: "'\\''")
		return run("printf '%s' '\(escaped)' > \(shellQuote(path))") != nil
	}

	func deleteItem(_ path: String) -> (success: Bool, trashedURL: URL?) {
		if rpcOK(op: "delete", params: ["path": path]) {
			return (true, nil)
		}
		return deleteItemRemote(path)
	}

	func moveItem(from: String, to: String) -> Bool {
		if rpcOK(op: "rename", params: ["path": from, "path2": to]) { return true }
		return run("mv \(shellQuote(from)) \(shellQuote(to))") != nil
	}

	func createFile(_ path: String) -> Bool {
		// 空ファイル作成: write op で空文字。
		if rpcOK(op: "write", params: ["path": path, "data": "", "encoding": "utf8"]) { return true }
		return run("touch \(shellQuote(path))") != nil
	}

	func modificationDate(_ path: String) -> Date? {
		if let result = rpcResult(op: "stat", params: ["path": path]),
		   let mtime = result["mtime"] as? Double {
			return Date(timeIntervalSince1970: mtime)
		}
		guard let epoch = run("stat -c %Y \(shellQuote(path)) 2>/dev/null || stat -f %m \(shellQuote(path)) 2>/dev/null")?.trimmingCharacters(in: .whitespacesAndNewlines),
			  let ts = TimeInterval(epoch) else { return nil }
		return Date(timeIntervalSince1970: ts)
	}

	func downloadFile(remotePath: String, to localURL: URL) -> Bool {
		// SCP directly
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
		let cp = sshControlPath(for: host)
		process.arguments = [
			"-o", "ControlMaster=auto", "-o", "ControlPath=\(cp)", "-o", "ControlPersist=600",
			"-o", "StrictHostKeyChecking=accept-new", "-q",
			"\(host):\(remotePath)", localURL.path
		]
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
			process.waitUntilExit()
			return process.terminationStatus == 0
		} catch {
			NSLog("[Belve] downloadFile scp failed: \(error)")
			return false
		}
	}

	func uploadFile(localURL: URL, to remotePath: String) -> Bool {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
		let cp = sshControlPath(for: host)
		process.arguments = [
			"-o", "ControlMaster=auto", "-o", "ControlPath=\(cp)", "-o", "ControlPersist=600",
			"-o", "StrictHostKeyChecking=accept-new", "-q", "-r",
			localURL.path, "\(host):\(remotePath)"
		]
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
			process.waitUntilExit()
			return process.terminationStatus == 0
		} catch {
			NSLog("[Belve] uploadFile scp failed: \(error)")
			return false
		}
	}

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

struct DevContainerProvider: WorkspaceProvider, RemoteProjectScoped {
	let host: String
	let workspace: String
	/// 該当プロジェクト ID。`RemoteRPCRegistry` のキーに使う (RPC が利用可能
	/// なら ls/git ops を control 経由に切り替える)。
	let projectId: UUID
	var projectIdForRPC: UUID { projectId }

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

	func fileExists(_ path: String) -> Bool {
		if let _ = rpcResult(op: "stat", params: ["path": path]) { return true }
		return run("test -f \(shellQuote(path)) && echo yes || echo no") == "yes"
	}

	func readFile(_ path: String) -> String? {
		if let result = rpcResult(op: "read", params: ["path": path]),
		   let content = result["content"] as? String { return content }
		return run("cat \(shellQuote(path))")
	}

	func writeFile(_ path: String, content: String) -> Bool {
		let b64 = Data(content.utf8).base64EncodedString()
		if rpcOK(op: "write", params: ["path": path, "data": b64, "encoding": "base64"]) { return true }
		let escaped = content.replacingOccurrences(of: "'", with: "'\\''")
		return run("printf '%s' '\(escaped)' > \(shellQuote(path))") != nil
	}

	func deleteItem(_ path: String) -> (success: Bool, trashedURL: URL?) {
		if rpcOK(op: "delete", params: ["path": path]) { return (true, nil) }
		return deleteItemRemote(path)
	}

	func moveItem(from: String, to: String) -> Bool {
		if rpcOK(op: "rename", params: ["path": from, "path2": to]) { return true }
		return run("mv \(shellQuote(from)) \(shellQuote(to))") != nil
	}

	func createFile(_ path: String) -> Bool {
		if rpcOK(op: "write", params: ["path": path, "data": "", "encoding": "utf8"]) { return true }
		return run("touch \(shellQuote(path))") != nil
	}

	func modificationDate(_ path: String) -> Date? {
		if let result = rpcResult(op: "stat", params: ["path": path]),
		   let mtime = result["mtime"] as? Double {
			return Date(timeIntervalSince1970: mtime)
		}
		guard let epoch = run("stat -c %Y \(shellQuote(path)) 2>/dev/null")?.trimmingCharacters(in: .whitespacesAndNewlines),
			  let ts = TimeInterval(epoch) else { return nil }
		return Date(timeIntervalSince1970: ts)
	}

	func downloadFile(remotePath: String, to localURL: URL) -> Bool {
		// Get container ID and RWS (container workspace path) from env file
		guard let info = resolveContainerInfo(host: host, workspace: workspace) else {
			NSLog("[Belve] downloadFile: cannot resolve container info")
			return false
		}
		let cid = info.cid
		// docker cp container:path to host tmp, then scp to local
		let tmpRemote = "/tmp/belve-download-\(ProcessInfo.processInfo.processIdentifier)"
		let containerPath: String
		if remotePath.hasPrefix("/") {
			containerPath = remotePath
		} else {
			// Resolve relative path against container's RWS (not host workspace)
			containerPath = (info.rws as NSString).appendingPathComponent(remotePath)
		}
		// SSH: docker cp + cat → pipe to local file
		let process = Process()
		let pipe = Pipe()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		let cp = sshControlPath(for: host)
		process.arguments = [
			"-o", "ControlMaster=auto", "-o", "ControlPath=\(cp)", "-o", "ControlPersist=600",
			"-o", "StrictHostKeyChecking=accept-new",
			host,
			"docker cp \(cid):\(shellQuote(containerPath)) \(tmpRemote) && cat \(tmpRemote) && rm -f \(tmpRemote)"
		]
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
		} catch {
			NSLog("[Belve] downloadFile devcontainer failed: \(error)")
			return false
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0, !data.isEmpty else {
			NSLog("[Belve] downloadFile devcontainer exit=%d dataSize=%d", process.terminationStatus, data.count)
			return false
		}
		do {
			try? FileManager.default.removeItem(at: localURL)
			try data.write(to: localURL)
			return true
		} catch {
			NSLog("[Belve] downloadFile write failed: \(error)")
			return false
		}
	}

	func uploadFile(localURL: URL, to remotePath: String) -> Bool {
		guard let info = resolveContainerInfo(host: host, workspace: workspace) else {
			NSLog("[Belve] uploadFile: cannot resolve container info")
			return false
		}
		let cid = info.cid
		let tmpRemote = "/tmp/belve-upload-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
		let containerPath: String
		if remotePath.hasPrefix("/") {
			containerPath = remotePath
		} else {
			containerPath = (info.rws as NSString).appendingPathComponent(remotePath)
		}

		// Step 1: scp local file → VM /tmp
		let scp = Process()
		scp.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
		let cp = sshControlPath(for: host)
		scp.arguments = [
			"-o", "ControlMaster=auto", "-o", "ControlPath=\(cp)", "-o", "ControlPersist=600",
			"-o", "StrictHostKeyChecking=accept-new", "-q", "-r",
			localURL.path, "\(host):\(tmpRemote)"
		]
		scp.standardError = FileHandle.nullDevice
		do {
			try scp.run()
			scp.waitUntilExit()
			guard scp.terminationStatus == 0 else {
				NSLog("[Belve] uploadFile devcontainer scp failed: exit=\(scp.terminationStatus)")
				return false
			}
		} catch {
			NSLog("[Belve] uploadFile devcontainer scp failed: \(error)")
			return false
		}

		// Step 2: ssh to VM, docker cp → container, rm tmp
		let ssh = Process()
		ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		ssh.arguments = [
			"-o", "ControlMaster=auto", "-o", "ControlPath=\(cp)", "-o", "ControlPersist=600",
			"-o", "StrictHostKeyChecking=accept-new",
			host,
			"docker cp \(tmpRemote) \(cid):\(shellQuote(containerPath)); rm -rf \(tmpRemote)"
		]
		ssh.standardError = FileHandle.nullDevice
		ssh.standardOutput = FileHandle.nullDevice
		do {
			try ssh.run()
			ssh.waitUntilExit()
			return ssh.terminationStatus == 0
		} catch {
			NSLog("[Belve] uploadFile devcontainer docker cp failed: \(error)")
			return false
		}
	}

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

struct ContainerInfo {
	let cid: String
	let rws: String
}

/// Resolve container ID and RWS from project env files on the SSH host.
/// Matches by the last path component of the workspace (e.g. "clay-app-report").
private func resolveContainerInfo(host: String, workspace: String) -> ContainerInfo? {
	let dirName = (workspace as NSString).lastPathComponent
	let cmd = "for f in ~/.belve/projects/*.env; do . \"$f\"; case \"$RWS\" in */\(dirName)) echo \"$CID $RWS\"; break;; esac; done"
	let result = executeSSH(host: host, cmd)
	guard let r = result, r.status == 0, !r.output.isEmpty else { return nil }
	let parts = r.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
	guard parts.count >= 2 else { return nil }
	return ContainerInfo(cid: parts[0], rws: parts.dropFirst().joined(separator: " "))
}

// MARK: - Shared Remote Helpers

private func listDirectoryRemote(_ path: String, run: (String) -> String?) -> [FileItem] {
	guard let output = run("ls -1aF \(shellQuote(path))") else { return [] }
	let items = output.components(separatedBy: "\n")
		.filter { !$0.isEmpty && $0 != "./" && $0 != "../" }
		.filter { entry in
			let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry.replacingOccurrences(of: "*", with: "")
			return !AppConfig.shared.shouldExclude(name)
		}
		.compactMap { entry -> FileItem? in
			let isDir = entry.hasSuffix("/")
			let name = isDir ? String(entry.dropLast()) : entry.replacingOccurrences(of: "*", with: "")
			let fullPath = (path as NSString).appendingPathComponent(name)
			return FileItem(name: name, path: fullPath, isDirectory: isDir)
		}
	return items.sortedLikeVSCode()
}

extension Array where Element == FileItem {
	/// Match VS Code's default explorer sort: folders first, then files.
	/// Within each group, case-insensitive natural compare — so dot-prefixed
	/// entries (e.g. `.gitignore`) naturally sort to the top of their group.
	func sortedLikeVSCode() -> [FileItem] {
		sorted { a, b in
			if a.isDirectory != b.isDirectory { return a.isDirectory }
			return a.name.localizedStandardCompare(b.name) == .orderedAscending
		}
	}
}

extension SSHProvider {
	fileprivate func listDirectoryRemote(_ path: String) -> [FileItem] {
		// RPC fast path: 既存 SSH port forward 越しに 1 TCP 往復で済む
		// (vs `ssh host ls` で ~20-50ms の fork/exec)。失敗 (RPC 未確立等)
		// なら従来の executeSSH 経路にフォールバック。
		if let items = listDirectoryViaRPC(projectId: projectId, path: path) {
			return items.sortedLikeVSCode()
		}
		return WorkspaceProvider_listDirectoryRemote(path, run: run)
	}
}

extension DevContainerProvider {
	fileprivate func listDirectoryRemote(_ path: String) -> [FileItem] {
		if let items = listDirectoryViaRPC(projectId: projectId, path: path) {
			return items.sortedLikeVSCode()
		}
		return WorkspaceProvider_listDirectoryRemote(path, run: run)
	}
}

// MARK: - RPC bridge (sync wrapper around RemoteRPCClient.send)

/// Block the calling thread until the RPC response (or error / timeout)
/// returns. Provider methods are sync; RPC is async. Bridging here keeps the
/// migration local (no need to make every call site async).
///
/// Returns nil if RPC isn't available for this project (no client registered)
/// — caller should fallback to `executeSSH`.
private func listDirectoryViaRPC(projectId: UUID, path: String) -> [FileItem]? {
	guard let client = RemoteRPCRegistry.shared.client(for: projectId) else {
		return nil
	}
	let res = syncRPC(client: client, op: "ls", params: ["path": path])
	guard let result = res?.result,
	      let entries = result["entries"] as? [[String: Any]]
	else { return nil }
	return entries.compactMap { e -> FileItem? in
		guard let name = e["name"] as? String,
		      let isDir = e["isDir"] as? Bool
		else { return nil }
		if AppConfig.shared.shouldExclude(name) { return nil }
		let fullPath = (path as NSString).appendingPathComponent(name)
		return FileItem(name: name, path: fullPath, isDirectory: isDir)
	}
}

func syncRPC(client: RemoteRPCClient, op: String, params: [String: Any]) -> RPCResponse? {
	let sem = DispatchSemaphore(value: 0)
	var out: RPCResponse?
	Task.detached {
		do {
			out = try await client.send(op: op, params: params)
		} catch {
			NSLog("[Belve][rpc] %@ failed: %@", op, error.localizedDescription)
		}
		sem.signal()
	}
	// 5s よりちょい余裕。client.send 側のタイムアウトに任せる。
	_ = sem.wait(timeout: .now() + 6.0)
	guard let res = out, res.ok else { return nil }
	return res
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

	/// For each given absolute path, test whether `<path>/.devcontainer/devcontainer.json`
	/// exists. Single SSH round-trip regardless of the number of paths.
	func findDevContainerDirs(in paths: [String]) -> Set<String> {
		guard !paths.isEmpty else { return [] }
		let quoted = paths.map { shellQuote("\($0)/.devcontainer/devcontainer.json") }.joined(separator: " ")
		let script = "for f in \(quoted); do [ -f \"$f\" ] && echo \"$f\"; done"
		guard let output = run(script), !output.isEmpty else { return [] }
		let suffix = "/.devcontainer/devcontainer.json"
		let results = output.split(separator: "\n").compactMap { line -> String? in
			let s = String(line)
			return s.hasSuffix(suffix) ? String(s.dropLast(suffix.count)) : nil
		}
		return Set(results)
	}
}

extension DevContainerProvider {
	fileprivate func deleteItemRemote(_ path: String) -> (success: Bool, trashedURL: URL?) {
		Belve.deleteItemRemote(path, run: run)
	}
}
