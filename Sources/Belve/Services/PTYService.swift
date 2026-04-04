import Foundation

/// Manages a PTY (pseudo-terminal) and spawned shell process.
/// Uses posix_spawn with POSIX_SPAWN_SETSID to prevent Terminal.app from activating.
class PTYService {
	let masterFd: Int32
	let pid: pid_t
	private var readSource: DispatchSourceRead?

	var onData: ((Data) -> Void)?

	private init(masterFd: Int32, pid: pid_t) {
		self.masterFd = masterFd
		self.pid = pid
	}

	/// Spawn a shell in a new PTY session.
	static func spawn(
		shell: String = "/bin/zsh",
		args: [String] = ["-l"],
		environment: [String: String]? = nil
	) throws -> PTYService {
		var master: Int32 = 0
		var slave: Int32 = 0

		guard openpty(&master, &slave, nil, nil, nil) == 0 else {
			throw PTYError.openptyFailed
		}

		// File actions: redirect stdin/stdout/stderr to slave PTY
		var fileActions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&fileActions)
		posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
		posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
		posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
		posix_spawn_file_actions_addclose(&fileActions, master)
		posix_spawn_file_actions_addclose(&fileActions, slave)

		// Spawn attributes: create new session (SETSID) to detach from Terminal.app
		var spawnAttr: posix_spawnattr_t?
		posix_spawnattr_init(&spawnAttr)
		posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_SETSID))

		// Build environment
		let home = NSHomeDirectory()
		var envDict = [
			"HOME": home,
			"TERM": "xterm-256color",
			"PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
			"LANG": "en_US.UTF-8",
			"SHELL": shell,
		]
		if let extra = environment {
			envDict.merge(extra) { _, new in new }
		}
		let envStrings = envDict.map { "\($0.key)=\($0.value)" }

		// Convert to C strings
		let cArgs = ([shell] + args).map { strdup($0) } + [nil]
		let cEnv = envStrings.map { strdup($0) } + [nil]

		var pid: pid_t = 0
		let result = cArgs.withUnsafeBufferPointer { argsPtr in
			cEnv.withUnsafeBufferPointer { envPtr in
				posix_spawn(
					&pid, shell, &fileActions, &spawnAttr,
					UnsafeMutablePointer(mutating: argsPtr.baseAddress!),
					UnsafeMutablePointer(mutating: envPtr.baseAddress!)
				)
			}
		}

		// Cleanup
		cArgs.forEach { if let p = $0 { free(p) } }
		cEnv.forEach { if let p = $0 { free(p) } }
		posix_spawn_file_actions_destroy(&fileActions)
		posix_spawnattr_destroy(&spawnAttr)
		close(slave)

		guard result == 0 else {
			close(master)
			throw PTYError.spawnFailed(errno: result)
		}

		let service = PTYService(masterFd: master, pid: pid)
		service.startReading()
		return service
	}

	/// Send data to the shell process.
	func send(_ data: Data) {
		data.withUnsafeBytes { ptr in
			let _ = write(masterFd, ptr.baseAddress!, ptr.count)
		}
	}

	/// Send string to the shell process.
	func send(_ string: String) {
		if let data = string.data(using: .utf8) {
			send(data)
		}
	}

	/// Update terminal window size.
	func setSize(cols: Int, rows: Int) {
		var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
		let _ = ioctl(masterFd, TIOCSWINSZ, &size)
	}

	private func startReading() {
		let fd = masterFd
		let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
		source.setEventHandler { [weak self] in
			var buf = [UInt8](repeating: 0, count: 8192)
			let n = read(fd, &buf, buf.count)
			if n > 0 {
				let data = Data(buf[0..<n])
				DispatchQueue.main.async {
					self?.onData?(data)
				}
			}
		}
		source.resume()
		self.readSource = source
	}

	deinit {
		readSource?.cancel()
		close(masterFd)
		kill(pid, SIGTERM)
	}
}

enum PTYError: Error {
	case openptyFailed
	case spawnFailed(errno: Int32)
}
