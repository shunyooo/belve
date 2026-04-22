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
	let host: String
	let port: UInt16

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

	init(host: String, port: UInt16) {
		self.host = host
		self.port = port
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
				stateLock.withLock { _ = pending.removeValue(forKey: id) }
				cont.resume(throwing: RPCError.connectionLost)
				return
			}
			conn.send(content: line, completion: .contentProcessed { [weak self] err in
				guard let self else { return }
				if let err {
					self.stateLock.withLock { _ = self.pending.removeValue(forKey: id) }
					cont.resume(throwing: err)
				}
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
		let endpoint = NWEndpoint.hostPort(
			host: NWEndpoint.Host(host),
			port: NWEndpoint.Port(integerLiteral: port)
		)
		let conn = NWConnection(to: endpoint, using: .tcp)
		var resumed = false
		conn.stateUpdateHandler = { [weak self] state in
			guard let self else { return }
			switch state {
			case .ready:
				self.connectionReady = true
				if !resumed { resumed = true; cont.resume() }
				self.startReading(conn)
			case .failed(let err), .waiting(let err):
				NSLog("[Belve][rpc] conn state=%@ host=%@ err=%@", "\(state)", self.host, err.localizedDescription)
				if !resumed { resumed = true; cont.resume(throwing: err) }
				// Existing pending requests will time out; trigger immediate
				// disconnect so the next send retries fresh.
				self.disconnect()
			case .cancelled:
				self.connectionReady = false
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
	private var localPorts: [UUID: UInt16] = [:]
	private let lock = NSLock()

	private init() {}

	/// Register the local port that's been forwarded to the project's control
	/// listener. Called by `ProjectStore.select` after `SSHTunnelManager` sets
	/// up the forward. Calling again with a different port replaces the client.
	func registerControlPort(projectId: UUID, localPort: UInt16) {
		let oldClient: RemoteRPCClient? = lock.withLock {
			if localPorts[projectId] == localPort { return nil }
			let prev = clients[projectId]
			localPorts[projectId] = localPort
			// Bypass DNS — always loopback (the SSH forward terminates locally).
			clients[projectId] = RemoteRPCClient(host: "127.0.0.1", port: localPort)
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
			localPorts.removeValue(forKey: projectId)
			return c
		}
		removed?.disconnect()
	}

	func teardownAll() {
		let snapshot: [RemoteRPCClient] = lock.withLock {
			let all = Array(clients.values)
			clients.removeAll()
			localPorts.removeAll()
			return all
		}
		for c in snapshot { c.disconnect() }
	}
}
