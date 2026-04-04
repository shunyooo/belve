import Foundation

/// Reads directory contents locally or via SSH.
enum FileService {
	static func listDirectory(path: String, sshHost: String? = nil) -> [FileItem] {
		if let host = sshHost {
			return listRemoteDirectory(path: path, host: host)
		}
		return listLocalDirectory(path: path)
	}

	private static func listLocalDirectory(path: String) -> [FileItem] {
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }

		return entries.sorted().compactMap { name in
			guard !name.hasPrefix(".") else { return nil } // skip hidden files
			let fullPath = (path as NSString).appendingPathComponent(name)
			var isDir: ObjCBool = false
			fm.fileExists(atPath: fullPath, isDirectory: &isDir)
			return FileItem(
				name: name,
				path: fullPath,
				isDirectory: isDir.boolValue
			)
		}
	}

	private static func listRemoteDirectory(path: String, host: String) -> [FileItem] {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		process.arguments = [
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=5",
			host,
			"ls -1F \(path)"
		]

		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		do {
			try process.run()
			process.waitUntilExit()
		} catch {
			NSLog("[Belve] SSH ls failed: \(error)")
			return []
		}

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		guard let output = String(data: data, encoding: .utf8) else { return [] }

		return output.components(separatedBy: .newlines).compactMap { line in
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty else { return nil }
			let isDir = trimmed.hasSuffix("/")
			let name = isDir ? String(trimmed.dropLast()) : trimmed
			guard !name.hasPrefix(".") else { return nil }
			let fullPath = (path as NSString).appendingPathComponent(name)
			return FileItem(
				name: name,
				path: fullPath,
				isDirectory: isDir
			)
		}
	}

	static func readFile(path: String, sshHost: String? = nil) -> String? {
		if let host = sshHost {
			return readRemoteFile(path: path, host: host)
		}
		return try? String(contentsOfFile: path, encoding: .utf8)
	}

	private static func readRemoteFile(path: String, host: String) -> String? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		process.arguments = [
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=5",
			host,
			"cat \(path)"
		]

		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		do {
			try process.run()
			process.waitUntilExit()
		} catch {
			NSLog("[Belve] SSH cat failed: \(error)")
			return nil
		}

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		return String(data: data, encoding: .utf8)
	}
}
