import Foundation

/// Deploys Belve CLI scripts to remote hosts via SSH.
enum BelveRemoteInstaller {
	/// Deploy belve + claude wrapper to ~/.belve/bin/ on remote host.
	/// Returns true if successful.
	@discardableResult
	static func deploy(to sshHost: String) -> Bool {
		let binDir = findLocalBinDir()
		guard let belveScript = try? String(contentsOfFile: binDir + "/belve"),
			  let claudeScript = try? String(contentsOfFile: binDir + "/claude")
		else {
			NSLog("[Belve] Failed to read local bin scripts")
			return false
		}

		// Create ~/.belve/bin/ and write scripts
		let setupCommand = """
		mkdir -p ~/.belve/bin && \
		cat > ~/.belve/bin/belve << 'BELVE_EOF'
		\(belveScript)
		BELVE_EOF
		chmod +x ~/.belve/bin/belve && \
		cat > ~/.belve/bin/claude << 'CLAUDE_EOF'
		\(claudeScript)
		CLAUDE_EOF
		chmod +x ~/.belve/bin/claude
		"""

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		process.arguments = [
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=10",
			sshHost,
			setupCommand,
		]
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice

		do {
			try process.run()
			process.waitUntilExit()
			let success = process.terminationStatus == 0
			NSLog("[Belve] Remote deploy to \(sshHost): \(success ? "OK" : "FAILED")")
			return success
		} catch {
			NSLog("[Belve] Remote deploy failed: \(error)")
			return false
		}
	}

	private static func findLocalBinDir() -> String {
		// App bundle: Belve.app/Contents/Resources/bin/
		if let resourceURL = Bundle.main.resourceURL {
			let bundleBin = resourceURL.appendingPathComponent("bin").path
			if FileManager.default.fileExists(atPath: bundleBin + "/belve") {
				return bundleBin
			}
		}
		// Development: Sources/Belve/Resources/bin/
		let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
		let devBin = execDir?
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Sources/Belve/Resources/bin")
		if let path = devBin?.path, FileManager.default.fileExists(atPath: path + "/belve") {
			return path
		}
		return ""
	}
}
