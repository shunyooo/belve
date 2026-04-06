import Foundation

/// Reads directory contents locally or via SSH.
enum FileService {
	static func fileExists(path: String, sshHost: String? = nil) -> Bool {
		if let host = sshHost {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
			process.arguments = [
				"-o", "StrictHostKeyChecking=accept-new",
				"-o", "ConnectTimeout=5",
				"-o", "BatchMode=yes",
				host,
				"test -f \(path)"
			]
			process.standardOutput = FileHandle.nullDevice
			process.standardError = FileHandle.nullDevice
			do {
				try process.run()
				process.waitUntilExit()
				return process.terminationStatus == 0
			} catch {
				return false
			}
		}
		return FileManager.default.fileExists(atPath: path)
	}

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

	static func writeFile(path: String, content: String, sshHost: String? = nil) -> Bool {
		if let host = sshHost {
			return writeRemoteFile(path: path, content: content, host: host)
		}
		do {
			try content.write(toFile: path, atomically: true, encoding: .utf8)
			NSLog("[Belve] File saved: \(path)")
			return true
		} catch {
			NSLog("[Belve] Failed to save file: \(error)")
			return false
		}
	}

	private static func writeRemoteFile(path: String, content: String, host: String) -> Bool {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		process.arguments = [
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=5",
			host,
			"cat > \(path)"
		]

		let inputPipe = Pipe()
		process.standardInput = inputPipe
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice

		do {
			try process.run()
			if let data = content.data(using: .utf8) {
				inputPipe.fileHandleForWriting.write(data)
			}
			inputPipe.fileHandleForWriting.closeFile()
			process.waitUntilExit()
			NSLog("[Belve] Remote file saved: \(host):\(path)")
			return process.terminationStatus == 0
		} catch {
			NSLog("[Belve] Failed to save remote file: \(error)")
			return false
		}
	}
}
