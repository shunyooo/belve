import Foundation
import Network

/// Mac-side TCP client for the belve-persist control RPC (NDJSON) running on
/// a remote VM / DevContainer. One instance per host; reused across all
/// projects on that host.
///
/// Why this exists: filesystem & git ops used to spawn `ssh host cmd` per
/// call, which costs ~20-50ms each over ControlMaster and triggers visible
/// flicker on 5s file-tree polling. With one persistent TCP connection (over
/// the existing SSH port forward), each op is a single NDJSON round-trip
/// (~1ms on local + IPC + remote read/dispatch).
///
/// Reliability:
///   - Auto-connects on first call. If the underlying TCP dies, the next call
///     reconnects (callers see one slow request, not a permanent failure).
///   - All requests have a 5s timeout to bound a stuck remote.
///   - Concurrent requests share one connection, multiplexed by `id`.
///
/// Thread safety: `sendCalls` and `pending` are guarded by `stateLock`. The
/// reader runs on a dedicated DispatchQueue and only writes to `pending`
/// under the lock.
final class RemoteRPCClient: @unchecked Sendable {
	/// Log label only. 実際の接続は muxVia (Unix socket) 経由で mac-master へ。
	let host: String
	/// VM router 経由で繋ぐときに送る preamble の projShort。
	let routeProjShort: String
	/// mac-master の per-host Unix socket path。yamux stream として control RPC を流す。
	let muxVia: String

	private var connection: NWConnection?
	private var pending: [String: CheckedContinuation<RPCResponse, Error>] = [:]
	private var nextID: Int = 0
	/// Background reader buffer for incoming NDJSON lines.
	private var readBuffer = Data()
	private let stateLock = NSLock()
	private let queue: DispatchQueue
	/// Connection state — only mutated on `queue` (or via lock for inspection).
	private var connectionReady = false
	/// Push-event handlers (file watch etc.). Multiple subscribers allowed.
	private var pushHandlers: [(String, [String: Any]) -> Void] = []
	/// 接続 (再) 確立時に呼ばれる handler。broker 側の per-connection state
	/// (fsnotify watch 等) は接続と共に消えるため、購読側はこれを受けて
	/// watch を登録し直す。初回接続でも発火する (再登録は冪等)。
	private var reconnectHandlers: [() -> Void] = []
	/// 初回接続を区別するためのフラグ (ログ用)。
	private var hasConnectedOnce = false

	init(host: String, routeProjShort: String, muxVia: String) {
		self.host = host
		self.routeProjShort = routeProjShort
		self.muxVia = muxVia
		self.queue = DispatchQueue(label: "belve.rpc.\(host)", qos: .userInitiated)
	}

	// MARK: - Public API

	/// Send a request, await response. Reconnects + retries once on the
	/// first transient failure (TCP died) so callers don't have to handle
	/// reconnection.
	func send(op: String, params: [String: Any] = [:]) async throws -> RPCResponse {
		do {
			return try await sendOnce(op: op, params: params)
		} catch RPCError.connectionLost {
			NSLog("[Belve][rpc] reconnect after lost connection host=%@", host)
			disconnect()
			return try await sendOnce(op: op, params: params)
		}
	}

	/// Subscribe to push events (no `id` in the message). Pass a closure that
	/// receives `(type, payload)`. Called on the RPC client's queue.
	func subscribePush(_ handler: @escaping (String, [String: Any]) -> Void) {
		stateLock.withLock { pushHandlers.append(handler) }
	}

	/// Subscribe to connection (re-)establishment. broker 側の per-connection
	/// state (fsnotify watch 等) は TCP 切断で消えるので、これを受けて再登録する。
	/// Called on the RPC client's queue.
	func subscribeReconnect(_ handler: @escaping () -> Void) {
		stateLock.withLock { reconnectHandlers.append(handler) }
	}

	/// Drop the connection. Next `send` will reconnect.
	func disconnect() {
		queue.async { [weak self] in
			guard let self else { return }
			self.connection?.cancel()
			self.connection = nil
			self.connectionReady = false
			let snapshot = self.stateLock.withLock { () -> [CheckedContinuation<RPCResponse, Error>] in
				let conts = Array(self.pending.values)
				self.pending.removeAll()
				return conts
			}
			for c in snapshot {
				c.resume(throwing: RPCError.connectionLost)
			}
			self.readBuffer = Data()
		}
	}

	// MARK: - Internals

	private func sendOnce(op: String, params: [String: Any]) async throws -> RPCResponse {
		try await ensureConnected()
		let id = stateLock.withLock { () -> String in
			nextID += 1
			return "\(nextID)"
		}
		var msg: [String: Any] = ["id": id, "op": op]
		for (k, v) in params { msg[k] = v }
		let line = try Self.encodeLine(msg)

		return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RPCResponse, Error>) in
			stateLock.withLock { pending[id] = cont }
			guard let conn = connection else {
				let target = stateLock.withLock { () -> CheckedContinuation<RPCResponse, Error>? in
					pending.removeValue(forKey: id)
				}
				target?.resume(throwing: RPCError.connectionLost)
				return
			}
			conn.send(content: line, completion: .contentProcessed { [weak self] err in
				guard let self, let err else { return }
				// pending[id] を atomic に take して、取れた時だけ resume する。
				// timeout / response 到着パスとの race で double resume → crash を防ぐ
				// (= 2026-04-24 SIGTRAP in CheckedContinuation.resume)。
				let target = self.stateLock.withLock { () -> CheckedContinuation<RPCResponse, Error>? in
					self.pending.removeValue(forKey: id)
				}
				target?.resume(throwing: err)
			})
			// Timeout: 5s. Long enough for slow SSH, short enough to fail loud.
			self.queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
				guard let self else { return }
				let cont = self.stateLock.withLock { () -> CheckedContinuation<RPCResponse, Error>? in
					self.pending.removeValue(forKey: id)
				}
				cont?.resume(throwing: RPCError.timeout(op: op))
			}
		}
	}

	private func ensureConnected() async throws {
		// Fast path: already connected.
		if connectionReady, connection != nil { return }
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			queue.async { [weak self] in
				guard let self else {
					cont.resume(throwing: RPCError.connectionLost)
					return
				}
				if self.connectionReady, self.connection != nil {
					cont.resume()
					return
				}
				self.connectInternal(then: cont)
			}
		}
	}

	private func connectInternal(then cont: CheckedContinuation<Void, Error>) {
		// 古い connection を先に同期で片付ける。`disconnect()` は queue.async で
		// 遅延実行されるため、先に enqueue された disconnect が「新しく作った
		// conn を cancel してしまう」「既に死んだ conn の handler が新 conn の
		// state を上書きする」といった race を防ぐ。
		if let old = connection {
			old.stateUpdateHandler = nil
			old.cancel()
			connection = nil
			connectionReady = false
		}
		// mac-master の per-host Unix socket に接続。
		// router preamble は接続後に送信する (= router 側で demux に使う)。
		let endpoint = NWEndpoint.unix(path: muxVia)
		let conn = NWConnection(to: endpoint, using: .tcp)
		var resumed = false
		conn.stateUpdateHandler = { [weak self] state in
			guard let self else { return }
			switch state {
			case .ready:
				// Phase B: router 経由の場合、最初に routing preamble を送る。
				// preamble がない場合 (legacy 直接接続) はスキップ。
				if !self.routeProjShort.isEmpty {
					let preamble = "{\"projShort\":\"\(self.routeProjShort)\",\"kind\":\"control\"}\n"
					if let data = preamble.data(using: .utf8) {
						conn.send(content: data, completion: .contentProcessed { _ in })
					}
				}
				self.connectionReady = true
				if !resumed { resumed = true; cont.resume() }
				self.startReading(conn)
				// 再接続 (2 回目以降の確立) を購読者に通知。broker の
				// per-connection watch を再登録させる。初回接続では発火しない
				// (= 通常経路の watch 登録と重複しないように)。
				let isReconnect = self.hasConnectedOnce
				self.hasConnectedOnce = true
				if isReconnect {
					let handlers = self.stateLock.withLock { self.reconnectHandlers }
					if !handlers.isEmpty {
						NSLog("[Belve][rpc] reconnected host=%@ — notifying %d watch subscribers", self.host, handlers.count)
						for h in handlers { h() }
					}
				}
			case .failed(let err), .waiting(let err):
				NSLog("[Belve][rpc] conn state=%@ host=%@ err=%@", "\(state)", self.host, err.localizedDescription)
				if !resumed { resumed = true; cont.resume(throwing: err) }
				// Existing pending requests will time out; trigger immediate
				// disconnect so the next send retries fresh.
				self.disconnect()
			case .cancelled:
				self.connectionReady = false
				// .ready / .failed / .waiting に到達する前に cancel されると
				// cont が永遠に未 resume となり、ensureConnected 呼び出し元が
				// 全停止する (= GitHub issue #1 の "SWIFT TASK CONTINUATION
				// MISUSE" の根本原因)。connectionLost で resume して回復可能に。
				if !resumed { resumed = true; cont.resume(throwing: RPCError.connectionLost) }
			default: break
			}
		}
		connection = conn
		conn.start(queue: queue)
	}

	private func startReading(_ conn: NWConnection) {
		conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
			guard let self else { return }
			if let data, !data.isEmpty {
				self.readBuffer.append(data)
				self.processBuffer()
			}
			if let err {
				NSLog("[Belve][rpc] receive err host=%@ %@", self.host, err.localizedDescription)
				self.disconnect()
				return
			}
			if isComplete {
				self.disconnect()
				return
			}
			// Continue reading
			self.startReading(conn)
		}
	}

	private func processBuffer() {
		while let nlIdx = readBuffer.firstIndex(of: 0x0A) {
			let line = readBuffer[..<nlIdx]
			readBuffer.removeSubrange(...nlIdx)
			guard !line.isEmpty,
			      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
			else { continue }
			if let id = obj["id"] as? String, !id.isEmpty {
				let cont = stateLock.withLock { () -> CheckedContinuation<RPCResponse, Error>? in
					pending.removeValue(forKey: id)
				}
				cont?.resume(returning: RPCResponse(raw: obj))
			} else if let type = obj["type"] as? String {
				if type == "fsevent" {
					NSLog("[Belve][RPC] push fsevent: %@", String(describing: obj))
				}
				let handlers = stateLock.withLock { pushHandlers }
				for h in handlers { h(type, obj) }
			}
		}
	}

	private static func encodeLine(_ obj: [String: Any]) throws -> Data {
		var data = try JSONSerialization.data(withJSONObject: obj, options: [])
		data.append(0x0A) // \n
		return data
	}
}

// MARK: - Response wrapper + errors

struct RPCResponse {
	let raw: [String: Any]
	var ok: Bool { raw["ok"] as? Bool ?? false }
	var error: String? { raw["error"] as? String }
	var result: [String: Any]? { raw["result"] as? [String: Any] }

	/// Throws if the response is an error response (`ok=false`).
	func throwIfError(op: String) throws {
		if !ok {
			throw RPCError.remote(op: op, message: error ?? "unknown error")
		}
	}
}

enum RPCError: LocalizedError {
	case connectionLost
	case timeout(op: String)
	case remote(op: String, message: String)

	var errorDescription: String? {
		switch self {
		case .connectionLost: return "RPC connection lost"
		case .timeout(let op): return "RPC \(op) timed out"
		case .remote(let op, let msg): return "RPC \(op) failed: \(msg)"
		}
	}
}

// MARK: - Per-host registry

/// One client per project. Provider methods (`gitStatus`, `listDirectory` 等)
/// are called from background queues during git/file polling, so the registry
/// can't be @MainActor — it'd hard-crash with a libdispatch assertion when
/// touched off-main. Use NSLock for per-access serialization instead.
final class RemoteRPCRegistry: @unchecked Sendable {
	static let shared = RemoteRPCRegistry()

	private var clients: [UUID: RemoteRPCClient] = [:]
	/// Cached `pwd` result per project (= broker cwd, which is the workspace
	/// root inside the container for DevContainer / on the VM for SSH). Used
	/// to resolve `./...` paths (DevContainer's `effectivePath = "."`) to a
	/// real absolute path for the file tree's "Copy Full Path" menu.
	private var cwds: [UUID: String] = [:]
	private let lock = NSLock()

	private init() {}

	func cwd(for projectId: UUID) -> String? {
		lock.withLock { cwds[projectId] }
	}

	func setCwd(_ cwd: String, for projectId: UUID) {
		lock.withLock { cwds[projectId] = cwd }
	}

	/// mux 経由で control RPC を確立する。yamux session は mac-master が host 単位
	/// で維持しており、Swift 側は per-host Unix socket に繋いで stream を開く。
	/// projShort は stream の preamble に入れて router 側で demux に使う。
	func registerControlMux(projectId: UUID, host: String, projShort: String) {
		let muxVia = MuxListenerPath.forHost(host)
		let oldClient: RemoteRPCClient? = lock.withLock {
			let prev = clients[projectId]
			clients[projectId] = RemoteRPCClient(
				host: host, routeProjShort: projShort, muxVia: muxVia
			)
			return prev
		}
		oldClient?.disconnect()
	}

	func client(for projectId: UUID) -> RemoteRPCClient? {
		lock.withLock { clients[projectId] }
	}

	func teardown(projectId: UUID) {
		let removed: RemoteRPCClient? = lock.withLock {
			let c = clients.removeValue(forKey: projectId)
			cwds.removeValue(forKey: projectId)
			return c
		}
		removed?.disconnect()
	}

	func teardownAll() {
		let snapshot: [RemoteRPCClient] = lock.withLock {
			let all = Array(clients.values)
			clients.removeAll()
			cwds.removeAll()
			return all
		}
		for c in snapshot { c.disconnect() }
	}
}
