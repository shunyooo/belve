import AppKit
import Foundation

/// Manages a PTY (pseudo-terminal) and spawned shell process.
/// Uses posix_spawn with POSIX_SPAWN_SETSID to prevent Terminal.app from activating.
class PTYService {
	let masterFd: Int32
	let pid: pid_t
	private var readSource: DispatchSourceRead?
	private let exitStateLock = NSLock()
	private var didExit = false

	var onData: ((Data) -> Void)?
	var onExit: ((Int32) -> Void)?
	var onNotification: ((String, String) -> Void)? // (title, body)
	var agentTransport = OSCAgentTransport()
	private var oscBuffer = ""

	/// PTY 読み取り → main への受け渡しを coalesce するためのバッファ。
	/// 背景の read ソースが `DispatchQueue.main.async` を read ごとに投げると、
	/// 再接続時の scrollback replay 等でデータが main の処理速度を超えて流入した際、
	/// main キューに `Data` を抱えたクロージャが無限に積まれ、数GB まで膨張する
	/// (実測: 再接続 1 回で 237MB→8GB)。pending に貯めて「未処理の main flush が
	/// 無い時だけ 1 個だけ」スケジュールすることで、main キューの滞留を常に 1 ブロック
	/// (coalesce 済み) に抑える。
	private var pendingOutput = Data()
	private let pendingLock = NSLock()
	private var flushScheduled = false
	/// main 1 hop で onData に渡す最大バイト数。giant chunk を一括処理して main を
	/// 長時間ブロックする (= UI freeze) のを防ぐ。超過分は次の runloop tick に回す。
	private static let maxFlushChunk = 256 * 1024
	/// pending に貯める上限。再接続時の scrollback replay 等でデータが処理速度を
	/// 恒常的に超えて流入する病的ケースで、古い側を捨てて total を有界に保つ
	/// (freeze も OOM も防ぐ)。端末は最新画面が見えれば十分なので、古い出力の欠落は
	/// 許容する (OSC/agent scan は read スレッドで生ストリームに対し済み → 影響なし)。
	private static let maxPendingBytes = 8 * 1024 * 1024

	private init(masterFd: Int32, pid: pid_t) {
		self.masterFd = masterFd
		self.pid = pid
	}

	/// Spawn a shell in a new PTY session.
	/// Defaults to $SHELL (user's login shell) or /bin/zsh as fallback.
	static func spawn(
		shell: String? = nil,
		args: [String] = ["-l"],
		environment: [String: String]? = nil,
		cols: Int = 80,
		rows: Int = 24
	) throws -> PTYService {
		var master: Int32 = 0
		var slave: Int32 = 0

		var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)

		// Configure PTY in raw mode: terminal emulator (xterm.js) handles
		// all rendering, so the PTY should not process output (OPOST) or echo.
		// This prevents double CR/LF when belve-persist stacks a second PTY.
		var rawTermios = termios()
		cfmakeraw(&rawTermios)

		guard openpty(&master, &slave, nil, &rawTermios, &size) == 0 else {
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

		// Resolve shell: explicit arg > $SHELL > /bin/zsh fallback
		let resolvedShell = shell
			?? ProcessInfo.processInfo.environment["SHELL"]
			?? "/bin/zsh"

		// Build environment
		let home = NSHomeDirectory()
		var envDict = [
			"HOME": home,
			"TERM": "xterm-256color",
			"PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
			"LANG": "en_US.UTF-8",
			"SHELL": resolvedShell,
		]
		if let extra = environment {
			envDict.merge(extra) { _, new in new }
		}
		let envStrings = envDict.map { "\($0.key)=\($0.value)" }

		// Convert to C strings
		let cArgs = ([resolvedShell] + args).map { strdup($0) } + [nil]
		let cEnv = envStrings.map { strdup($0) } + [nil]

		var pid: pid_t = 0
		let result = cArgs.withUnsafeBufferPointer { argsPtr in
			cEnv.withUnsafeBufferPointer { envPtr in
				posix_spawn(
					&pid, resolvedShell, &fileActions, &spawnAttr,
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
		service.startMonitoringExit()
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
		// PTY has no controlling terminal (POSIX_SPAWN_SETSID without Setctty),
		// so TIOCSWINSZ doesn't trigger SIGWINCH.
		// Send SIGWINCH to the foreground process group of the PTY slave.
		var fpgid: pid_t = 0
		if ioctl(masterFd, TIOCGPGRP, &fpgid) == 0, fpgid > 0 {
			NSLog("[Belve] setSize cols=%d rows=%d pid=%d fpgid=%d", cols, rows, pid, fpgid)
			kill(-fpgid, SIGWINCH)
		} else {
			NSLog("[Belve] setSize cols=%d rows=%d pid=%d (no fpgid, using -pid)", cols, rows, pid)
			kill(-pid, SIGWINCH)
		}
	}

	private func startReading() {
		let fd = masterFd
		let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
		source.setEventHandler { [weak self] in
			var buf = [UInt8](repeating: 0, count: 65536)
			let n = read(fd, &buf, buf.count)
			if n > 0 {
				let data = Data(buf[0..<n])
				// OSC / agent スキャンは read スレッドで生ストリームに対して行う
				// (順序を保つ。coalesce の前段)。
				self?.agentTransport.scan(data)
				self?.scanForOSC(data)
				self?.enqueueOutput(data)
			} else {
				source.cancel()
			}
		}
		source.resume()
		self.readSource = source
	}

	/// 読み取ったデータを pending に貯め、未スケジュールの時だけ main flush を予約する。
	/// main へは 1 回につき最大 `maxFlushChunk` だけ渡し、残りは次 tick に回すことで
	/// giant chunk による main ブロック (UI freeze) を防ぐ。さらに pending が
	/// `maxPendingBytes` を超えたら古い側を捨てて total を有界化する (flood 時の
	/// メモリ暴走を防ぐ)。通常負荷では pending は小さく、slice/drop は一切発動しない。
	private func enqueueOutput(_ data: Data) {
		pendingLock.lock()
		pendingOutput.append(data)
		if pendingOutput.count > Self.maxPendingBytes {
			let drop = pendingOutput.count - Self.maxPendingBytes
			pendingOutput.removeFirst(drop)
			NSLog("[Belve] PTY flood: dropped %d stale bytes to cap backlog", drop)
		}
		let needSchedule = !flushScheduled
		if needSchedule { flushScheduled = true }
		pendingLock.unlock()
		guard needSchedule else { return }
		scheduleFlush()
	}

	/// pending から最大 `maxFlushChunk` を切り出して main で onData に渡す。まだ残って
	/// いれば自分自身を再スケジュールして続きを流す (= 各 hop は短く UI に譲る)。
	private func scheduleFlush() {
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.pendingLock.lock()
			let take = min(self.pendingOutput.count, Self.maxFlushChunk)
			let chunk = self.pendingOutput.prefix(take)
			self.pendingOutput.removeFirst(take)
			let more = !self.pendingOutput.isEmpty
			self.flushScheduled = more
			self.pendingLock.unlock()
			if take > 0 { self.onData?(Data(chunk)) }
			if more { self.scheduleFlush() }
		}
	}

	private func startMonitoringExit() {
		let childPid = pid
		DispatchQueue.global(qos: .utility).async { [weak self] in
			var status: Int32 = 0
			let result = waitpid(childPid, &status, 0)
			guard result == childPid else { return }
			self?.finishExit(status: status)
		}
	}

	private func finishExit(status: Int32) {
		exitStateLock.lock()
		defer { exitStateLock.unlock() }
		guard !didExit else { return }
		didExit = true
		readSource?.cancel()
		DispatchQueue.main.async { [weak self] in
			self?.onExit?(status)
		}
	}

	private static let oscPatterns: [NSRegularExpression?] = [
		try? NSRegularExpression(pattern: "\u{1b}\\]9;([^\u{07}\u{1b}]*)[\u{07}]"),
		try? NSRegularExpression(pattern: "\u{1b}\\]99;([^\u{07}\u{1b}]*)[\u{07}]"),
		try? NSRegularExpression(pattern: "\u{1b}\\]777;notify;([^;]*);([^\u{07}\u{1b}]*)[\u{07}]"),
		try? NSRegularExpression(pattern: "\u{1b}\\]52;[^;]*;([A-Za-z0-9+/=]+)(?:\u{07}|\u{1b}\\\\)"),
	]

	/// Scan for OSC 9/99/777 notification sequences: \e]9;text\a or \e]9;text\e\\
	private func scanForOSC(_ data: Data) {
		guard let str = String(data: data, encoding: .utf8), !str.isEmpty else { return }
		// OSC 開始シーケンス (\e]) も BEL (\x07) もなければ skip
		let hasOSC = str.contains("\u{1b}]") || str.contains("\u{07}")
		if !hasOSC && oscBuffer.isEmpty { return }
		oscBuffer += str

		let patterns = Self.oscPatterns
		let nsStr = oscBuffer as NSString
		let range = NSRange(location: 0, length: nsStr.length)
		var maxConsumedLocation = 0

		for pattern in patterns.prefix(2) {
			pattern?.enumerateMatches(in: oscBuffer, range: range) { match, _, _ in
				guard let match,
					  let bodyRange = Range(match.range(at: 1), in: self.oscBuffer) else { return }
				maxConsumedLocation = max(maxConsumedLocation, match.range.upperBound)
				let body = String(self.oscBuffer[bodyRange])
				DispatchQueue.main.async { [weak self] in
					self?.onNotification?("Terminal", body)
				}
			}
		}

		patterns[2]?.enumerateMatches(in: oscBuffer, range: range) { match, _, _ in
			guard let match,
				  let titleRange = Range(match.range(at: 1), in: self.oscBuffer),
				  let bodyRange = Range(match.range(at: 2), in: self.oscBuffer) else { return }
			maxConsumedLocation = max(maxConsumedLocation, match.range.upperBound)
			let title = String(self.oscBuffer[titleRange])
			let body = String(self.oscBuffer[bodyRange])
			DispatchQueue.main.async { [weak self] in
				self?.onNotification?(title, body)
			}
		}

		patterns[3]?.enumerateMatches(in: oscBuffer, range: range) { match, _, _ in
			guard let match,
				  let encodedRange = Range(match.range(at: 1), in: self.oscBuffer) else { return }
			maxConsumedLocation = max(maxConsumedLocation, match.range.upperBound)
			let encoded = String(self.oscBuffer[encodedRange])
			guard let data = Data(base64Encoded: encoded),
				  let text = String(data: data, encoding: .utf8),
				  !text.isEmpty else { return }
			DispatchQueue.main.async {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(text, forType: .string)
			}
		}

		if maxConsumedLocation > 0 {
			oscBuffer = String(nsStr.substring(from: maxConsumedLocation))
		} else if oscBuffer.count > 8192 {
			oscBuffer = String(oscBuffer.suffix(2048))
		}
	}

	deinit {
		readSource?.cancel()
		close(masterFd)
		exitStateLock.lock()
		let alreadyExited = didExit
		exitStateLock.unlock()
		if !alreadyExited {
			kill(pid, SIGTERM)
		}
	}
}

enum PTYError: Error {
	case openptyFailed
	case spawnFailed(errno: Int32)
}
