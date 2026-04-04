import Foundation

/// Manages DevContainer lifecycle via `devcontainer` CLI.
enum DevContainerService {
	/// Start a DevContainer on a remote host.
	/// Returns the container ID if successful.
	static func up(sshHost: String, workspacePath: String) -> String? {
		NSLog("[Belve] DevContainer up: \(sshHost):\(workspacePath)")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		process.arguments = [
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=10",
			sshHost,
			"cd \(workspacePath) && devcontainer up --workspace-folder . 2>&1 | tail -1"
		]

		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice

		do {
			try process.run()
			process.waitUntilExit()
		} catch {
			NSLog("[Belve] DevContainer up failed: \(error)")
			return nil
		}

		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
			return nil
		}

		NSLog("[Belve] DevContainer up output: \(output)")

		// Parse container ID from JSON output
		if let jsonData = output.data(using: .utf8),
		   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
		   let containerId = json["containerId"] as? String {
			return containerId
		}

		return nil
	}

	/// Execute a command inside a running DevContainer.
	static func exec(sshHost: String, workspacePath: String, command: String = "/bin/bash") -> [String] {
		return [
			"/usr/bin/ssh",
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ServerAliveInterval=30",
			"-t",
			sshHost,
			"cd \(workspacePath) && devcontainer exec --workspace-folder . \(command)"
		]
	}
}
