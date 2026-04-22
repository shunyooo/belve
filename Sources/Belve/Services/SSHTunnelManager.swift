import Foundation
import Darwin

/// Manages local TCP port allocation and SSH port-forward teardown for remote projects.
///
/// **Tunnel establishment is done by the launcher bash script** (it has the right sequence:
/// deploy → belve-setup → read container IP → `ssh -O forward`). Swift reserves the local
/// port up-front and cancels the forward on project close / app exit.
///
/// One SSH ControlMaster per host (opened by launcher on first connect); every pane reuses
/// the same master via the shared ControlPath `/tmp/belve-ssh-ctrl-<host>`. This is what
/// collapses "one SSH session per pane" down to "one SSH session per host".
///
/// Thread-safety: `stateLock` protects the dicts. Blocking `ssh -O cancel` calls run on a
/// background queue from `teardownTunnel`; `teardownAll` is synchronous (called at app exit).
final class SSHTunnelManager: @unchecked Sendable {
	static let shared = SSHTunnelManager()

	/// host → projectId → local port (PTY broker forward)
	private var tunnels: [String: [UUID: Int]] = [:]
	/// host → projectId → local port (control RPC forward)
	private var controlTunnels: [String: [UUID: Int]] = [:]
	private var allocatedPorts: Set<Int> = []
	/// Dedup `ensureControlMaster` calls for the same host while spawn is in flight.
	/// Cleared on completion (success or failure) so a later death of the master
	/// doesn't pin us to a stale task.
	private var inflightMasters: [String: Task<Void, Error>] = [:]
	/// Dedup in-flight control-forward establishment per (host, project).
	private var inflightControlForwards: [String: Task<Int, Error>] = [:]
	/// host → projectId → "LPORT:RADDR:RPORT" — needed for `ssh -O cancel -L`
	/// (which requires the EXACT spec used at forward time).
	private var controlSpecs: [String: [UUID: String]] = [:]
	private let stateLock = NSLock()

	private let basePort = 19222
	private let maxPort = 19322

	private init() {}

	// MARK: - Public API

	/// Reserve a local port for (host, projectId). Idempotent: returns the same port on
	/// repeat calls. Does NOT execute any SSH — the launcher establishes the forward
	/// once deploy+setup have populated `~/.belve/projects/<short>.env`.
	func reservePort(host: String, projectId: UUID) throws -> Int {
		stateLock.lock()
		defer { stateLock.unlock() }
		if let existing = tunnels[host]?[projectId] {
			return existing
		}
		for port in basePort...maxPort {
			guard !allocatedPorts.contains(port) else { continue }
			guard Self.isPortFree(port) else { continue }
			tunnels[host, default: [:]][projectId] = port
			allocatedPorts.insert(port)
			NSLog("[Belve][tunnel] reserved host=%@ project=%@ port=%d",
				  host, String(projectId.uuidString.prefix(8)), port)
			return port
		}
		throw TunnelError.noPortAvailable
	}

	/// Ensure an SSH ControlMaster exists for `host`. Idempotent + dedup'd:
	/// concurrent callers for the same host share one in-flight spawn task.
	///
	/// Why this exists: `ssh -O forward` requires an existing master. On Belve
	/// startup, `PortForwardManager.sync` runs before any terminal pane has
	/// triggered the launcher script (which is what historically established
	/// the master), so all forwards fail with "Could not connect to server".
	/// Letting the manager call this first restores forwards on cold start.
	///
	/// Mirrors the launcher's exact flags so both share the same socket.
	func ensureControlMaster(host: String) async throws {
		// Fast path: master already alive
		if Self.checkMaster(host: host) { return }

		// Async-safe locking: NSLock isn't allowed across awaits under Swift 6.
		let task = stateLock.withLock { () -> Task<Void, Error> in
			if let existing = inflightMasters[host] {
				return existing
			}
			let new = Task { [host] in
				try await Self.spawnAndWaitForMaster(host: host)
			}
			inflightMasters[host] = new
			return new
		}

		defer {
			stateLock.withLock { _ = inflightMasters.removeValue(forKey: host) }
		}
		try await task.value
	}

	/// Set up Mac → remote control-RPC forward for (host, project). Allocates a
	/// local port, runs `ssh -O forward -L LPORT:remoteAddr:remotePort host`,
	/// and returns the local port so the caller can hand it to
	/// `RemoteRPCRegistry.shared.registerControlPort(...)`.
	///
	/// Idempotent — repeat calls return the same port; concurrent callers for
	/// the same project share an in-flight task.
	///
	/// `remoteAddr` is `127.0.0.1` for plain SSH (broker bound to VM loopback)
	/// and the container IP for DevContainer (broker bound to 0.0.0.0 inside
	/// the container). The caller is responsible for figuring out which.
	func ensureControlChannel(
		host: String,
		projectId: UUID,
		remoteAddr: String,
		remotePort: Int = 19224
	) async throws -> Int {
		// Fast path
		if let existing = stateLock.withLock({ controlTunnels[host]?[projectId] }) {
			return existing
		}
		let key = "\(host)#\(projectId.uuidString)"
		let task: Task<Int, Error> = stateLock.withLock {
			if let inflight = inflightControlForwards[key] { return inflight }
			let new = Task<Int, Error> { [weak self] in
				guard let self else { throw TunnelError.noPortAvailable }
				try await SSHTunnelManager.shared.ensureControlMaster(host: host)
				let port = try self.allocateLocalPort(map: \SSHTunnelManager.controlTunnels, host: host, projectId: projectId)
				let spec = "\(port):\(remoteAddr):\(remotePort)"
				let ok = await Self.runForward(host: host, local: port, remoteHost: remoteAddr, remotePort: remotePort)
				if !ok {
					self.stateLock.withLock {
						self.controlTunnels[host]?[projectId] = nil
						self.allocatedPorts.remove(port)
					}
					throw TunnelError.forwardFailed
				}
				self.stateLock.withLock {
					self.controlSpecs[host, default: [:]][projectId] = spec
				}
				NSLog("[Belve][tunnel] control forward host=%@ project=%@ local=%d → %@:%d",
					  host, String(projectId.uuidString.prefix(8)), port, remoteAddr, remotePort)
				return port
			}
			inflightControlForwards[key] = new
			return new
		}
		defer {
			stateLock.withLock { _ = inflightControlForwards.removeValue(forKey: key) }
		}
		return try await task.value
	}

	/// Tear down the forward for a specific (host, project). Runs `ssh -O cancel` off the
	/// main thread. Safe to call even if no tunnel is registered.
	func teardownTunnel(host: String, projectId: UUID) {
		stateLock.lock()
		let ptyPort = tunnels[host]?[projectId]
		let ctlPort = controlTunnels[host]?[projectId]
		let ctlSpec = controlSpecs[host]?[projectId]
		if ptyPort != nil {
			tunnels[host]?[projectId] = nil
			if tunnels[host]?.isEmpty == true { tunnels[host] = nil }
			allocatedPorts.remove(ptyPort!)
		}
		if ctlPort != nil {
			controlTunnels[host]?[projectId] = nil
			if controlTunnels[host]?.isEmpty == true { controlTunnels[host] = nil }
			allocatedPorts.remove(ctlPort!)
		}
		if ctlSpec != nil {
			controlSpecs[host]?[projectId] = nil
			if controlSpecs[host]?.isEmpty == true { controlSpecs[host] = nil }
		}
		stateLock.unlock()
		guard ptyPort != nil || ctlPort != nil else { return }

		DispatchQueue.global(qos: .utility).async {
			if let port = ptyPort {
				Self.cancelForward(host: host, projectId: projectId, localPort: port)
				NSLog("[Belve][tunnel] closed host=%@ project=%@ port=%d",
					  host, String(projectId.uuidString.prefix(8)), port)
			}
			if let spec = ctlSpec {
				Self.cancelForwardSpec(host: host, spec: spec)
				NSLog("[Belve][tunnel] closed control host=%@ project=%@ spec=%@",
					  host, String(projectId.uuidString.prefix(8)), spec)
			}
		}
	}

	/// Tear down all forwards (app exit or stale cleanup). Blocks until each cancel completes.
	/// Also exits every leftover SSH master socket found under `/tmp/belve-ssh-ctrl-*`
	/// so we can't inherit zombie forwards across app restarts — those were the source of
	/// "Port forwarding failed" / "mux_client_forward: forwarding request failed" errors
	/// when a new reservation picked a local port that the persisted master still held.
	func teardownAll() {
		stateLock.lock()
		let snapshot = tunnels
		tunnels.removeAll()
		allocatedPorts.removeAll()
		stateLock.unlock()

		for (host, projects) in snapshot {
			for (projectId, port) in projects {
				Self.cancelForward(host: host, projectId: projectId, localPort: port)
			}
		}
		Self.killAllSSHMasters()
		Self.clearAllSpecFiles()
		NSLog("[Belve][tunnel] teardownAll done")
	}

	/// Drop every `*.spec` file under `/tmp/belve-shell/tunnels/`. The spec
	/// file is the launcher script's cache of the last forward it
	/// established; stale entries (esp. duplicates from past races where two
	/// projects were assigned the same local port) cause the `-O cancel`
	/// step to target a spec that doesn't match the master's actual forward,
	/// leaving the subsequent `-O forward` to fail with "Port forwarding
	/// failed". Wiping the cache on startup forces the launcher to always
	/// issue a fresh forward against the newly-created master.
	private static func clearAllSpecFiles() {
		let dir = "/tmp/belve-shell/tunnels"
		guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
		for entry in entries where entry.hasSuffix(".spec") {
			try? FileManager.default.removeItem(atPath: "\(dir)/\(entry)")
		}
	}

	/// Enumerate `/tmp/belve-ssh-ctrl-*` and exit every master we find. Forces the next
	/// pane connect to open a fresh ControlMaster, which is cheap (ControlPath reuse) and
	/// guarantees no stale forwards survive.
	///
	/// After requesting graceful exit we also pkill any lingering master processes and
	/// wait until the local port range (19222-19322) is genuinely free. Without the wait,
	/// `reservePort()` runs immediately after, sees the port as briefly bindable (race),
	/// and a new project inherits a port that the old master still technically holds —
	/// which is what produced the "mux_client_forward: Port forwarding failed" errors.
	private static func killAllSSHMasters() {
		let dir = "/tmp"
		let prefix = "belve-ssh-ctrl-"
		guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
		for entry in entries where entry.hasPrefix(prefix) {
			let hostSpec = String(entry.dropFirst(prefix.count))
			let proc = Process()
			proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
			proc.arguments = [
				"-o", "ControlPath=\(dir)/\(entry)",
				"-O", "exit",
				hostSpec,
			]
			proc.standardOutput = FileHandle.nullDevice
			proc.standardError = FileHandle.nullDevice
			try? proc.run()
			proc.waitUntilExit()
			try? FileManager.default.removeItem(atPath: "\(dir)/\(entry)")
		}
		// Hard-kill any master process that didn't respect `ssh -O exit`.
		let pkill = Process()
		pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
		pkill.arguments = ["-f", "ssh.*ControlMaster=yes.*ControlPath=/tmp/belve-ssh-ctrl-"]
		pkill.standardOutput = FileHandle.nullDevice
		pkill.standardError = FileHandle.nullDevice
		try? pkill.run()
		pkill.waitUntilExit()
		// Wait up to ~500ms for the reserved range to become bindable.
		let samplePort = 19222
		for _ in 0..<10 {
			if isPortFree(samplePort) { break }
			Thread.sleep(forTimeInterval: 0.05)
		}
	}

	// MARK: - Helpers

	/// Path must match the launcher's `BELVE_SSH_CONTROL` so both share one ControlMaster.
	private static func controlPath(for host: String) -> String {
		"/tmp/belve-ssh-ctrl-\(host)"
	}

	/// Allocate a free local port and record it in the given map (under lock).
	/// Called for both PTY forwards (`tunnels`) and control forwards
	/// (`controlTunnels`).
	private func allocateLocalPort(
		map keyPath: ReferenceWritableKeyPath<SSHTunnelManager, [String: [UUID: Int]]>,
		host: String,
		projectId: UUID
	) throws -> Int {
		try stateLock.withLock {
			if let existing = self[keyPath: keyPath][host]?[projectId] {
				return existing
			}
			for port in basePort...maxPort {
				guard !allocatedPorts.contains(port) else { continue }
				guard Self.isPortFree(port) else { continue }
				self[keyPath: keyPath][host, default: [:]][projectId] = port
				allocatedPorts.insert(port)
				return port
			}
			throw TunnelError.noPortAvailable
		}
	}

	/// `ssh -O forward -L LPORT:remoteAddr:remotePort host` against an
	/// existing ControlMaster. Returns `true` on success.
	@discardableResult
	private static func runForward(host: String, local: Int, remoteHost: String, remotePort: Int) async -> Bool {
		await Task.detached(priority: .userInitiated) {
			let proc = Process()
			proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
			proc.arguments = [
				"-o", "ControlPath=\(controlPath(for: host))",
				"-O", "forward",
				"-L", "\(local):\(remoteHost):\(remotePort)",
				host,
			]
			proc.standardOutput = FileHandle.nullDevice
			proc.standardError = FileHandle.nullDevice
			do { try proc.run() } catch { return false }
			proc.waitUntilExit()
			return proc.terminationStatus == 0
		}.value
	}

	/// `ssh -O check` returns 0 iff the master's control socket is alive and accepting
	/// commands. Cheap (no network round-trip).
	private static func checkMaster(host: String) -> Bool {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		proc.arguments = [
			"-o", "ControlPath=\(controlPath(for: host))",
			"-O", "check",
			host,
		]
		proc.standardOutput = FileHandle.nullDevice
		proc.standardError = FileHandle.nullDevice
		do {
			try proc.run()
		} catch {
			return false
		}
		proc.waitUntilExit()
		return proc.terminationStatus == 0
	}

	/// Spawn the master in the background (`-fN`) using the launcher's exact flags,
	/// then poll `checkMaster` until it accepts commands (~5s budget).
	private static func spawnAndWaitForMaster(host: String) async throws {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		proc.arguments = [
			"-o", "ControlMaster=yes",
			"-o", "ControlPath=\(controlPath(for: host))",
			"-o", "ControlPersist=600",
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=10",
			"-fN",
			host,
		]
		proc.standardOutput = FileHandle.nullDevice
		proc.standardError = FileHandle.nullDevice
		try proc.run()
		proc.waitUntilExit()
		// `-fN` forks; the parent we just waited on is the wrapper, the master
		// is the daemonized child. Poll until the socket responds.
		for _ in 0..<50 {
			if checkMaster(host: host) {
				NSLog("[Belve][tunnel] master up host=%@", host)
				return
			}
			try await Task.sleep(nanoseconds: 100_000_000) // 100ms
		}
		NSLog("[Belve][tunnel] master spawn timed out host=%@", host)
		throw TunnelError.masterFailed(host: host)
	}

	private static func isPortFree(_ port: Int) -> Bool {
		let sock = socket(AF_INET, SOCK_STREAM, 0)
		guard sock >= 0 else { return false }
		defer { close(sock) }
		var yes: Int32 = 1
		setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
		var addr = sockaddr_in()
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = UInt16(port).bigEndian
		addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
		let result = withUnsafePointer(to: &addr) { ptr in
			ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
				Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		return result == 0
	}

	/// Cancel a forward whose spec is known explicitly. Used for control
	/// forwards (Swift-managed, no .spec file written by launcher).
	private static func cancelForwardSpec(host: String, spec: String) {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		proc.arguments = [
			"-o", "ControlPath=\(controlPath(for: host))",
			"-O", "cancel",
			"-L", spec,
			host,
		]
		proc.standardOutput = FileHandle.nullDevice
		proc.standardError = FileHandle.nullDevice
		try? proc.run()
		proc.waitUntilExit()
	}

	/// Cancel the forward. `ssh -O cancel` requires the EXACT spec used when forwarding
	/// (local port + remote target). The launcher writes the spec to `<tunnelDir>/<projId>.spec`;
	/// if that file is missing (e.g. project was never connected), we fall back to a
	/// placeholder remote target — which will no-op for DevContainers but is harmless.
	private static func cancelForward(host: String, projectId: UUID, localPort: Int) {
		let specFile = "/tmp/belve-shell/tunnels/\(projectId.uuidString).spec"
		let spec: String
		if let contents = try? String(contentsOfFile: specFile, encoding: .utf8),
		   !contents.trimmingCharacters(in: .whitespaces).isEmpty {
			spec = contents.trimmingCharacters(in: .whitespacesAndNewlines)
		} else {
			spec = "\(localPort):127.0.0.1:19222"
		}
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		proc.arguments = [
			"-o", "ControlPath=\(controlPath(for: host))",
			"-O", "cancel",
			"-L", spec,
			host,
		]
		proc.standardOutput = FileHandle.nullDevice
		proc.standardError = FileHandle.nullDevice
		try? proc.run()
		proc.waitUntilExit()
		try? FileManager.default.removeItem(atPath: specFile)
	}

	// MARK: - Errors

	enum TunnelError: LocalizedError {
		case noPortAvailable
		case masterFailed(host: String)
		case forwardFailed

		var errorDescription: String? {
			switch self {
			case .noPortAvailable:
				return "No local port available in range 19222-19322"
			case .masterFailed(let host):
				return "Failed to establish SSH ControlMaster for \(host)"
			case .forwardFailed:
				return "ssh -O forward failed"
			}
		}
	}
}
