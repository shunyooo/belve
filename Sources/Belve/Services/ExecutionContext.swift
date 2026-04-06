import Foundation

/// Unified execution context — encapsulates "where commands run".
/// All file operations, directory listing, and command execution go through this.
enum ExecutionContext: Codable, Hashable {
	case local
	case ssh(host: String)
	case devContainer(host: String, workspacePath: String)

	/// Execute a shell command and return stdout.
	func run(_ command: String) -> String? {
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
		let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
		NSLog("[Belve] ExecutionContext.run result: \(result?.prefix(100) ?? "nil") (rc=\(process.terminationStatus))")
		return result
	}

	/// List directory contents.
	func listDirectory(_ path: String) -> [FileItem] {
		guard let output = run("ls -1F \(shellQuote(path))") else { return [] }
		return output.components(separatedBy: "\n")
			.filter { !$0.isEmpty }
			.sorted()
			.compactMap { entry in
				let isDir = entry.hasSuffix("/")
				let name = isDir ? String(entry.dropLast()) : entry.replacingOccurrences(of: "*", with: "")
				guard !name.hasPrefix(".") else { return nil }
				let fullPath = (path as NSString).appendingPathComponent(name)
				return FileItem(name: name, path: fullPath, isDirectory: isDir)
			}
	}

	/// Check if a file exists.
	func fileExists(_ path: String) -> Bool {
		let output = run("test -f \(shellQuote(path)) && echo yes || echo no")
		return output == "yes"
	}

	/// Read file contents.
	func readFile(_ path: String) -> String? {
		run("cat \(shellQuote(path))")
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

	private func sshArgs(host: String) -> [String] {
		[
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=5",
			"-o", "BatchMode=yes",
			host,
		]
	}

	private func shellQuote(_ path: String) -> String {
		if path.hasPrefix("~") || path == "." || path.hasPrefix("/") { return path }
		return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
	}
}
