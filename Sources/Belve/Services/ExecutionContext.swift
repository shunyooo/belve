import Foundation

/// Unified execution context — encapsulates "where commands run".
/// All file operations, directory listing, and command execution go through this.
enum ExecutionContext: Codable, Hashable {
	case local
	case ssh(host: String)
	case devContainer(host: String, workspacePath: String)

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
			.filter { !$0.hasPrefix(".") }
			.sorted()
			.map { name in
				let fullPath = (path as NSString).appendingPathComponent(name)
				var isDir: ObjCBool = false
				fm.fileExists(atPath: fullPath, isDirectory: &isDir)
				return FileItem(name: name, path: fullPath, isDirectory: isDir.boolValue)
			}
	}

	private func listDirectoryRemote(_ path: String) -> [FileItem] {
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
}
