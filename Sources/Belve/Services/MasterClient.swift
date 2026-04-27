import Foundation
import Network

/// Mac master daemon (`belve-persist -mac-master`) との IPC client。
/// Belve.app から Unix socket (NDJSON) で master に op を投げる。
///
/// Phase 1: ping / version op だけ。Phase 2 以降で ensureSetup / openSession 等を追加。
/// 詳細設計: docs/notes/2026-04-23-mac-master-design.md
///
/// Lifecycle:
///   - 起動時に `MasterClient.shared.bootstrap()` を呼ぶ
///   - socket が応答すれば既存の master に attach
///   - 応答なければ master を spawn してから attach
///   - master の死活は「次の send で connection lost → 再 spawn → 再 attach」で復活
final class MasterClient: @unchecked Sendable {
	static let shared = MasterClient()

	/// Master が listen する socket の絶対パス。固定 (= 多重起動防止 + 再接続容易)。
	static let socketPath = "/tmp/belve-master.sock"

	/// MasterClient が要求する master version。`bootstrap` 時の version op で
	/// これと違ったら master を kill → spawn し直して新版に attach する
	/// (= broker version negotiation の Mac 版)。
	static let expectedVersion = "1.2"

	private let queue = DispatchQueue(label: "belve.master", qos: .userInitiated)
	private var connection: NWConnection?
	private var pending: [String: CheckedContinuation<MasterResponse, Error>] = [:]
	private var nextID: Int = 0
	private var readBuffer = Data()
	private let stateLock = NSLock()
	private var connectionReady = false
	/// spawn した master の Process を保持。Foundation の Process は ARC で
	/// 死ぬとは限らないが (posix_spawn で detach 済み)、参照を維持して `terminate()`
	/// 等を後から呼べるようにする保険。実際には spawn 後 Belve.app が落ちても
	/// master は生き続ける設計。
	private var spawnedMasterProcess: Process?

	private init() {}

	// MARK: - Bootstrap

	/// 起動時に呼ぶ。Master が居なければ spawn し、ping で疎通確認、version
	/// 確認まで終えて返る。失敗したら throw。
	@discardableResult
	func bootstrap() async throws -> String {
		NSLog("[Belve][master] bootstrap step=probe-existing")
		// 1. 既存 socket に ping 試行。socket file が無くても、orphan (file あるが listener
		//    無し) でも NWConnection が ECONNREFUSED を伝えず永遠に preparing になる事が
		//    あるので、最初に BSD socket で同期 probe → orphan を確実に検出して cleanup。
		if FileManager.default.fileExists(atPath: Self.socketPath) {
			if !Self.bsdProbeUnixSocket(path: Self.socketPath) {
				NSLog("[Belve][master] orphan socket (refuses connect) → cleanup")
				try? FileManager.default.removeItem(atPath: Self.socketPath)
			} else if let version = try? await fetchVersionWithTimeout(seconds: 1.5) {
				if version == Self.expectedVersion {
					// Binary identity check: 一致なら attach、不一致なら **警告のみ**
					// (auto-kill しない)。Master を kill すると router port forward が
					// 死亡 → per-pane belve-persist client が TCP backend を失い、
					// 全 pane が PTY exit する → 全 terminal が固まる
					// (2026-04-27 事故)。stale master 問題は手動 pkill で対処、
					// 自動化は per-pane の auto-reconnect が入ってから。
					if let bundled = bundledBinaryIdentity(),
					   let existing = try? await fetchBinaryIdentity(),
					   existing != bundled {
						NSLog("[Belve][master] WARN binary identity mismatch existing=(mtime=%lld size=%lld) bundled=(mtime=%lld size=%lld) — attaching anyway (manual `pkill -f mac-master` to refresh)",
							existing.mtime, existing.size, bundled.mtime, bundled.size)
					}
					NSLog("[Belve][master] attached to existing master version=%@", version)
					return version
				}
				NSLog("[Belve][master] version mismatch existing=%@ expected=%@ → restart", version, Self.expectedVersion)
				killExistingMaster()
			} else {
				NSLog("[Belve][master] existing socket but no response → kill")
				killExistingMaster()
			}
		} else {
			NSLog("[Belve][master] no existing socket")
		}
		// 2. spawn → 起動待ち → version 確認
		NSLog("[Belve][master] bootstrap step=spawn")
		try spawnMaster()
		NSLog("[Belve][master] bootstrap step=waitUntilReady")
		let version = try await waitUntilReady(maxRetries: 25, intervalSeconds: 0.2)
		guard version == Self.expectedVersion else {
			throw MasterError.versionMismatch(got: version, want: Self.expectedVersion)
		}
		NSLog("[Belve][master] spawned master version=%@", version)
		return version
	}

	// MARK: - Public ops

	func ping() async throws -> Bool {
		let res = try await send(op: "ping", params: [:])
		return res.ok
	}

	func version() async throws -> String {
		let res = try await send(op: "version", params: [:])
		guard let v = res.result?["version"] as? String else {
			throw MasterError.malformedResponse("version missing")
		}
		return v
	}

	/// 既存 master の binary identity を取得する。version 応答に
	/// `binaryMtime` (Unix epoch sec) + `binarySize` (bytes) が入る。
	/// macMasterVersion を上げ忘れても、binary が変われば respawn できる安全網。
	private struct BinaryIdentity: Equatable {
		let mtime: Int64
		let size: Int64
	}

	private func fetchBinaryIdentity() async throws -> BinaryIdentity? {
		let res = try await send(op: "version", params: [:])
		guard let result = res.result,
		      let mtime = result["binaryMtime"] as? Int64,
		      let size = result["binarySize"] as? Int64
		else {
			// 古い master は binaryMtime を返さない → nil で「比較不能」を伝える。
			return nil
		}
		return BinaryIdentity(mtime: mtime, size: size)
	}

	/// App bundle 内の binary の identity を読む。Spawn しようとしている binary と
	/// 既存 master の binary を比較する用。
	/// BSD socket で同期 probe する。NWConnection が orphan unix socket file
	/// (= file あるが listener なし) で ECONNREFUSED を伝えず preparing で固まる
	/// バグを回避するためのプリチェック。Connect 試行を 500ms timeout で打ち切る。
	/// Returns true if the socket has a real listener.
	static func bsdProbeUnixSocket(path: String) -> Bool {
		let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
		if fd < 0 { return false }
		defer { Darwin.close(fd) }
		// Set non-blocking so connect returns immediately
		var flags = fcntl(fd, F_GETFL, 0)
		flags |= O_NONBLOCK
		_ = fcntl(fd, F_SETFL, flags)

		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		// Copy path bytes into sun_path (=104 byte fixed array)
		let pathBytes = path.utf8CString
		guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
		_ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
			ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
				pathBytes.withUnsafeBufferPointer { src in
					dst.update(from: src.baseAddress!, count: pathBytes.count)
				}
			}
		}
		let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
		let rc = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(fd, $0, addrLen)
			}
		}
		if rc == 0 { return true }
		// Non-blocking connect: EINPROGRESS = in flight, poll for completion
		if errno != EINPROGRESS { return false }
		var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
		let pollRc = poll(&pfd, 1, 500) // 500ms
		if pollRc <= 0 { return false }
		var soErr: Int32 = 0
		var soErrLen = socklen_t(MemoryLayout<Int32>.size)
		_ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soErrLen)
		return soErr == 0
	}

	private func bundledBinaryIdentity() -> BinaryIdentity? {
		guard let path = locateBinary(),
		      let attrs = try? FileManager.default.attributesOfItem(atPath: path),
		      let mtime = attrs[.modificationDate] as? Date,
		      let size = attrs[.size] as? NSNumber
		else { return nil }
		return BinaryIdentity(mtime: Int64(mtime.timeIntervalSince1970), size: size.int64Value)
	}

	/// Project の setup (deploy_bundle + ssh belve-setup) を master 側で
	/// 実行する。Idempotent: 既に done なら即返却、進行中なら同期待ち、
	/// failed/idle なら走らせる。per-host で直列化されるので並列に呼んでも安全。
	///
	/// `binDir` は Belve.app が認識している binary の置き場 (.app bundle)。
	/// master process は自分の path から推測することもできるが、明示的に
	/// 渡す方が場所変更に対してロバストで Belve.app との依存関係も明示的になる。
	@discardableResult
	func ensureSetup(
		projectId: UUID,
		host: String,
		isDevContainer: Bool,
		workspacePath: String,
		projShort: String,
		binDir: String
	) async throws -> Bool {
		let res = try await send(op: "ensureSetup", params: [
			"projectId": projectId.uuidString,
			"host": host,
			"isDevContainer": isDevContainer,
			"workspacePath": workspacePath,
			"projShort": projShort,
			"binDir": binDir,
		])
		if !res.ok {
			throw MasterError.setupFailed(res.error ?? "unknown")
		}
		return true
	}

	/// container rebuild / broker 死亡など、setup を再実行させたい時に呼ぶ。
	func invalidateSetup(projectId: UUID) async throws {
		_ = try await send(op: "invalidateSetup", params: [
			"projectId": projectId.uuidString,
		])
	}

	/// host への SSH ControlMaster を保証する (spawn if missing)。
	/// PortForwardManager が独自の port forward を立てる前に呼ぶ。
	func ensureControlMaster(host: String) async throws {
		_ = try await send(op: "ensureControlMaster", params: [
			"host": host,
		])
	}

	/// Per-VM router への port forward を保証する。Mac 側が listen する local
	/// port (= belve-persist client の `-tcpbackend` の接続先) を返す。
	/// host あたり 1 個の forward (Phase B 設計、複数 project で共有)。
	func ensureRouterForward(host: String, remotePort: Int = 19200) async throws -> Int {
		let res = try await send(op: "ensureRouterForward", params: [
			"host": host,
			"remotePort": remotePort,
		])
		guard let port = res.result?["localPort"] as? Int else {
			throw MasterError.malformedResponse("localPort missing from ensureRouterForward")
		}
		return port
	}

	func teardownAllTunnels() async throws {
		_ = try await send(op: "teardownAllTunnels", params: [:])
	}

	/// Host の failure cache を即時クリア + stale ControlMaster socket を掃除。
	/// Cmd+R / overlay の Retry ボタン経由で呼ぶ。次の ensureSetup で SSH 再試行。
	func resetHostHealth(host: String) async throws {
		_ = try await send(op: "resetHostHealth", params: ["host": host])
	}

	/// Mac 上の `localPath` (画像等) を SSH ControlMaster 経由で remote に
	/// コピーし、remote 側のパス (`/tmp/belve-clipboard/<basename>`) を返す。
	/// DevContainer の場合は VM 経由で `docker exec -i` でコンテナ内に書く。
	func transferImage(host: String, isDevContainer: Bool, projShort: String, localPath: String) async throws -> String {
		let res = try await send(op: "transferImage", params: [
			"host": host,
			"isDevContainer": isDevContainer,
			"projShort": projShort,
			"localPath": localPath,
		])
		guard let path = res.result?["remotePath"] as? String else {
			throw MasterError.malformedResponse("remotePath missing from transferImage")
		}
		return path
	}

	/// DevContainer の rebuild を master に依頼する。長時間 op (~30-120s)。
	/// 進捗は別途 `subscribePush("rebuildProgress") { payload in ... }` で受ける
	/// (= payload contains `projectId`, `phase`, `line`)。本メソッドは最終結果
	/// (success/failure) を await で返す。
	@discardableResult
	func rebuildSetup(
		projectId: UUID,
		host: String,
		workspacePath: String,
		projShort: String,
		binDir: String,
		forceRebuild: Bool = true
	) async throws -> Bool {
		let res = try await send(op: "rebuildSetup", params: [
			"projectId": projectId.uuidString,
			"host": host,
			"workspacePath": workspacePath,
			"projShort": projShort,
			"binDir": binDir,
			"forceRebuild": forceRebuild,
		])
		if !res.ok {
			throw MasterError.rebuildFailed(res.error ?? "unknown")
		}
		return true
	}

	// MARK: - Send

	/// Send a request, await response. Auto-recover on transient failures:
	/// - connectionLost (= connection.cancel was called or peer EOF):
	///     disconnect + retry (もう一度 connect 試行)
	/// - connectFailed (= /tmp/belve-master.sock に listener がいない、master が
	///     死んでる): bootstrap 走らせて master を respawn → retry
	///   無限再帰にならないよう、再帰中の bootstrap 失敗はそのまま throw。
	func send(op: String, params: [String: Any]) async throws -> MasterResponse {
		do {
			return try await sendOnce(op: op, params: params)
		} catch MasterError.connectionLost {
			NSLog("[Belve][master] reconnect after lost connection")
			disconnect()
			return try await sendOnceOrRespawn(op: op, params: params)
		} catch MasterError.connectFailed(let m) {
			NSLog("[Belve][master] connect failed (%@) — respawning master", m)
			disconnect()
			return try await respawnAndSend(op: op, params: params)
		}
	}

	/// 1 回 sendOnce 試して、connectFailed なら respawn してから再試行 (1 回だけ)。
	/// disconnect 直後の retry path で master が既に死んでた場合のフォールバック。
	private func sendOnceOrRespawn(op: String, params: [String: Any]) async throws -> MasterResponse {
		do {
			return try await sendOnce(op: op, params: params)
		} catch MasterError.connectFailed(let m) {
			NSLog("[Belve][master] reconnect failed (%@) — respawning master", m)
			disconnect()
			return try await respawnAndSend(op: op, params: params)
		}
	}

	/// 並行 respawn を防ぐための直列化 task。複数 send() が同時に connectFailed を
	/// 食らった時、各々が killExistingMaster → spawn を独立に走らせると新 master が
	/// 互いに kill し合ってループする。先頭 1 個が respawn を実行、残りはその完了を待つ。
	private var respawnTask: Task<Void, Error>? = nil

	/// killExistingMaster + spawnMaster + waitUntilReady を直列に実行してから再 send。
	private func respawnAndSend(op: String, params: [String: Any]) async throws -> MasterResponse {
		let task: Task<Void, Error> = stateLock.withLock {
			if let existing = respawnTask {
				return existing
			}
			let newTask = Task<Void, Error> { [weak self] in
				guard let self else { return }
				try? FileManager.default.removeItem(atPath: Self.socketPath)
				self.killExistingMaster()
				try self.spawnMaster()
				_ = try await self.waitUntilReady(maxRetries: 25, intervalSeconds: 0.2)
			}
			respawnTask = newTask
			return newTask
		}
		do {
			try await task.value
		} catch {
			stateLock.withLock { respawnTask = nil }
			throw error
		}
		stateLock.withLock { respawnTask = nil }
		return try await sendOnce(op: op, params: params)
	}

	private func sendOnce(op: String, params: [String: Any]) async throws -> MasterResponse {
		try await ensureConnected()
		let id = stateLock.withLock { () -> String in
			nextID += 1
			return "\(nextID)"
		}
		var msg: [String: Any] = ["id": id, "op": op]
		if !params.isEmpty { msg["params"] = params }
		let line = try Self.encodeLine(msg)

		return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MasterResponse, Error>) in
			stateLock.withLock { pending[id] = cont }
			guard let conn = connection else {
				let target = stateLock.withLock { () -> CheckedContinuation<MasterResponse, Error>? in
					pending.removeValue(forKey: id)
				}
				target?.resume(throwing: MasterError.connectionLost)
				return
			}
			conn.send(content: line, completion: .contentProcessed { [weak self] err in
				guard let self, let err else { return }
				// pending[id] を atomic に take して、取れた時だけ resume する。
				// processBuffer (response) や disconnect (connectionLost) と race して
				// double resume → SIGSEGV in os_unfair_lock_lock を防ぐ
				// (= 2026-04-24 belve.master queue crash)。
				let target = self.stateLock.withLock { () -> CheckedContinuation<MasterResponse, Error>? in
					self.pending.removeValue(forKey: id)
				}
				target?.resume(throwing: MasterError.sendFailed(err.localizedDescription))
			})
		}
	}

	// MARK: - Connection

	private func ensureConnected() async throws {
		if stateLock.withLock({ connectionReady }) { return }
		try await connect()
	}

	private func connect() async throws {
		// 古い NWConnection が残っていたら明示的に cancel + nil してから新規 connect。
		// 重ね張り (= bootstrap で probe → killExistingMaster → 再 connect の流れ) 時に
		// 旧 connection の callback と新 connection の操作が race して
		// Network framework 内部 lock が壊れて SIGSEGV するのを防ぐ
		// (= 2026-04-24 belve.master queue crash in os_unfair_lock_lock)。
		if let old = stateLock.withLock({ () -> NWConnection? in
			let c = connection
			connection = nil
			connectionReady = false
			return c
		}) {
			old.stateUpdateHandler = nil  // callback を切ってから cancel (再入抑制)
			old.cancel()
		}

		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			let endpoint = NWEndpoint.unix(path: Self.socketPath)
			let params = NWParameters.tcp  // unix socket は SOCK_STREAM 相当
			let conn = NWConnection(to: endpoint, using: params)
			let resumed = ResumedFlag()
			conn.stateUpdateHandler = { [weak self] state in
				guard let self else { return }
				switch state {
				case .ready:
					self.stateLock.withLock { self.connectionReady = true }
					self.startReader(on: conn)
					if resumed.tryResume() { cont.resume() }
				case .failed(let err):
					self.stateLock.withLock { self.connectionReady = false }
					if resumed.tryResume() { cont.resume(throwing: MasterError.connectFailed(err.localizedDescription)) }
				case .cancelled:
					self.stateLock.withLock { self.connectionReady = false }
				default:
					break
				}
			}
			stateLock.withLock { self.connection = conn }
			conn.start(queue: self.queue)
		}
	}

	/// Continuation の二重 resume を防ぐ atomic flag (NWConnection の
	/// stateUpdateHandler が複数回呼ばれる可能性に対する保険)。
	private final class ResumedFlag: @unchecked Sendable {
		private let lock = NSLock()
		private var done = false
		func tryResume() -> Bool {
			lock.lock(); defer { lock.unlock() }
			if done { return false }
			done = true
			return true
		}
	}

	private func disconnect() {
		// connect() と同じく callback を切ってから cancel して再入を防ぐ。
		let (oldConn, conts) = stateLock.withLock { () -> (NWConnection?, [CheckedContinuation<MasterResponse, Error>]) in
			let c = connection
			connection = nil
			connectionReady = false
			let snapshot = Array(pending.values)
			pending.removeAll()
			readBuffer = Data()
			return (c, snapshot)
		}
		oldConn?.stateUpdateHandler = nil
		oldConn?.cancel()
		for c in conts { c.resume(throwing: MasterError.connectionLost) }
	}

	private func startReader(on conn: NWConnection) {
		conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
			guard let self else { return }
			if let data, !data.isEmpty {
				self.readBuffer.append(data)
				self.processBuffer()
			}
			if let err {
				NSLog("[Belve][master] reader error: %@", err.localizedDescription)
				self.disconnect()
				return
			}
			if isComplete {
				self.disconnect()
				return
			}
			self.startReader(on: conn)
		}
	}

	/// Push event subscribers, keyed by event type ("rebuildProgress" 等)。
	/// Multiple closures per type allowed; callbacks fire on the IPC queue.
	private var pushHandlers: [String: [(([String: Any]) -> Void)]] = [:]

	/// Subscribe to a master push event (= response with no `id`, has `type`).
	/// 例: rebuildSetup の進捗 stream を `subscribePush("rebuildProgress") { ... }` で受ける。
	func subscribePush(type: String, handler: @escaping ([String: Any]) -> Void) {
		stateLock.withLock {
			pushHandlers[type, default: []].append(handler)
		}
	}

	private func processBuffer() {
		while let nlIndex = readBuffer.firstIndex(of: 0x0A) {
			let line = readBuffer.prefix(upTo: nlIndex)
			readBuffer.removeSubrange(0...nlIndex)
			guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
			// Push event (no id, has type) → dispatch to subscribers
			if obj["id"] == nil, let type = obj["type"] as? String {
				let payload = obj["payload"] as? [String: Any] ?? [:]
				let handlers = stateLock.withLock { pushHandlers[type] ?? [] }
				for h in handlers { h(payload) }
				continue
			}
			let id = obj["id"] as? String ?? ""
			let ok = obj["ok"] as? Bool ?? false
			let result = obj["result"] as? [String: Any]
			let errStr = obj["error"] as? String
			let resp = MasterResponse(id: id, ok: ok, result: result, error: errStr)
			let cont = stateLock.withLock { pending.removeValue(forKey: id) }
			cont?.resume(returning: resp)
		}
	}

	// MARK: - Spawn / version probe

	private func fetchVersionWithTimeout(seconds: Double) async throws -> String {
		try await withThrowingTaskGroup(of: String.self) { group in
			group.addTask { try await self.version() }
			group.addTask {
				try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
				throw MasterError.timeout
			}
			let result = try await group.next()!
			group.cancelAll()
			return result
		}
	}

	private func waitUntilReady(maxRetries: Int, intervalSeconds: Double) async throws -> String {
		for i in 0..<maxRetries {
			if FileManager.default.fileExists(atPath: Self.socketPath) {
				if let v = try? await fetchVersionWithTimeout(seconds: 0.5) {
					NSLog("[Belve][master] waitUntilReady ready after attempt=%d", i + 1)
					return v
				}
			}
			try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
		}
		throw MasterError.spawnTimeout
	}

	private func spawnMaster() throws {
		guard let bin = locateBinary() else {
			throw MasterError.binaryMissing
		}
		// stderr をログファイルに転送 (デバッグ用)。stdout/stdin は捨てる。
		let logURL = URL(fileURLWithPath: "/tmp/belve-master.log")
		FileManager.default.createFile(atPath: logURL.path, contents: nil)
		let logHandle = try FileHandle(forWritingTo: logURL)
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: bin)
		proc.arguments = ["-mac-master", Self.socketPath]
		proc.standardInput = FileHandle.nullDevice
		proc.standardOutput = logHandle
		proc.standardError = logHandle
		// Master daemon は Belve.app 終了後も生きて欲しい (= 次の起動で再 attach
		// できるように)。BELVE_PARENT_PID を継承すると watchParent で自殺するので
		// 明示的に取り除く。
		var env = ProcessInfo.processInfo.environment
		env.removeValue(forKey: "BELVE_PARENT_PID")
		proc.environment = env
		try proc.run()
		NSLog("[Belve][master] spawned pid=%d bin=%@", proc.processIdentifier, bin)
		stateLock.withLock { self.spawnedMasterProcess = proc }
	}

	private func killExistingMaster() {
		// /tmp/belve-master.sock を listen している既存プロセスを見つけて kill。
		// fuser/lsof を使ってもいいが、socket file を消すだけだと bind されてる
		// プロセスは生き続けるので pgrep でパターンマッチして TERM を送る。
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
		proc.arguments = ["-f", "belve-persist.*-mac-master"]
		proc.standardOutput = FileHandle.nullDevice
		proc.standardError = FileHandle.nullDevice
		try? proc.run()
		proc.waitUntilExit()
		// socket file も掃除 (master は起動時に Remove するが念の為)。
		try? FileManager.default.removeItem(atPath: Self.socketPath)
	}

	private func locateBinary() -> String? {
		// アプリバンドル内の belve-persist (Darwin arm64)。
		if let bundle = Bundle.main.resourcePath {
			let p = (bundle as NSString).appendingPathComponent("bin/belve-persist-darwin-arm64")
			if FileManager.default.fileExists(atPath: p) { return p }
		}
		// 開発時 fallback: SPM build 直叩きの場合は Resources が入らないので、
		// プロジェクトルートからの相対パスを探す。本番では走らない経路。
		let dev = "/Users/s07309/src/dock-code/Belve.app/Contents/Resources/bin/belve-persist-darwin-arm64"
		if FileManager.default.fileExists(atPath: dev) { return dev }
		return nil
	}

	// MARK: - Encode helper

	private static func encodeLine(_ msg: [String: Any]) throws -> Data {
		var data = try JSONSerialization.data(withJSONObject: msg)
		data.append(0x0A)  // '\n'
		return data
	}
}

struct MasterResponse {
	let id: String
	let ok: Bool
	let result: [String: Any]?
	let error: String?
}

enum MasterError: LocalizedError {
	case binaryMissing
	case spawnTimeout
	case connectFailed(String)
	case connectionLost
	case sendFailed(String)
	case versionMismatch(got: String, want: String)
	case malformedResponse(String)
	case timeout
	case setupFailed(String)
	case rebuildFailed(String)

	var errorDescription: String? {
		switch self {
		case .binaryMissing: return "belve-persist binary not found in app bundle"
		case .spawnTimeout: return "master did not become ready within 5s"
		case .connectFailed(let m): return "connect to master failed: \(m)"
		case .connectionLost: return "master connection lost"
		case .sendFailed(let m): return "send to master failed: \(m)"
		case .versionMismatch(let got, let want): return "master version mismatch got=\(got) want=\(want)"
		case .malformedResponse(let m): return "malformed master response: \(m)"
		case .timeout: return "master request timed out"
		case .setupFailed(let m): return "project setup failed: \(m)"
		case .rebuildFailed(let m): return "rebuild failed: \(m)"
		}
	}
}
