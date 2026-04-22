import Foundation
import Darwin

/// Manages user-facing TCP port forwards (local → remote) on top of the SSH
/// ControlMaster already opened by `SSHTunnelManager`. Separate from
/// SSHTunnelManager because that one is specialised for the belve-persist
/// broker forward and has different lifecycle assumptions (one per project,
/// port reserved up-front, spec file written by the launcher bash script).
///
/// Here the forwards are *user-visible* resources — they can be added,
/// toggled, and torn down at will, and we track runtime status so the UI can
/// show "listening / conflict / unreachable" badges.
///
/// Threading: all public API runs on the main actor so the `@Published`
/// dictionaries can be read from SwiftUI directly without extra hops. SSH
/// subprocess calls are dispatched to a background queue.
@MainActor
final class PortForwardManager: ObservableObject {
	static let shared = PortForwardManager()

	enum Status: Equatable {
		case establishing
		case active
		case remapped(actualLocal: Int)  // requested port was busy, we picked another
		case conflict                     // requested port busy and user-specified → no remap
		case unreachable                  // forward established but no TCP response on remote side
		case error(String)
	}

	/// projectId → forward.id → status
	@Published private(set) var statuses: [UUID: [UUID: Status]] = [:]
	/// projectId → effective local port (may differ from requested when remapped)
	@Published private(set) var effectiveLocalPorts: [UUID: [UUID: Int]] = [:]
	/// Remote listening ports currently surfaced to the user as toasts. Keyed
	/// by projectId; the value is the set of remote ports awaiting a
	/// Forward / Never / Always decision.
	@Published private(set) var pendingDetections: [UUID: Set<Int>] = [:]

	private var healthTimer: Timer?
	private var scanTimer: Timer?
	/// projectId → last scan snapshot (remote ports seen as listening)
	private var lastSeenRemotePorts: [UUID: Set<Int>] = [:]
	/// (host, projShort, isDevContainer) for active scans
	private var scanContexts: [UUID: ScanContext] = [:]

	private struct ScanContext {
		let host: String
		let projShort: String
		let isDevContainer: Bool
	}

	/// Well-known ports auto-detect must never surface. Adds SSH, belve's
	/// broker, and anything system-reserved (< 1024).
	private static let systemReservedPorts: Set<Int> = [22, 19222]
	/// Set of (projectId, forwardId) currently considered "established" with
	/// SSH. Used so teardown can skip cancelling forwards we never created.
	private var establishedForwards: Set<ForwardKey> = []

	private struct ForwardKey: Hashable {
		let projectId: UUID
		let forwardId: UUID
	}

	private init() {
		startHealthTimer()
		startScanTimer()
	}

	// MARK: - Public API

	/// Ensure all enabled forwards for the given project are established.
	/// Called when a project is selected / reloaded, and when the forward list
	/// changes. Idempotent: forwards already established are left alone.
	///
	/// For DevContainer projects the remote host is resolved at sync time from
	/// the container `.env` on the VM (CIP=…) so forwards hit the container
	/// directly rather than the VM's 127.0.0.1 (where nothing is listening
	/// unless the user published the port via docker).
	func sync(project: Project, host: String, remoteHost: String) {
		Task { [weak self] in
			let effectiveRemoteHost: String
			if project.isDevContainer {
				let projShort = String(project.id.uuidString.prefix(8))
				if let cip = await Self.fetchContainerIP(host: host, projShort: projShort) {
					effectiveRemoteHost = cip
				} else {
					effectiveRemoteHost = remoteHost
				}
			} else {
				effectiveRemoteHost = remoteHost
			}
			await self?.syncAsync(project: project, host: host, remoteHost: effectiveRemoteHost)
		}
	}

	func teardown(projectId: UUID, host: String) {
		Task { [weak self] in
			await self?.teardownAll(projectId: projectId, host: host)
		}
		scanContexts.removeValue(forKey: projectId)
		lastSeenRemotePorts.removeValue(forKey: projectId)
		pendingDetections.removeValue(forKey: projectId)
	}

	/// Register a project for remote listening-port scanning. Called when the
	/// project is selected (or connection info becomes known). Unregister via
	/// `teardown` above.
	func registerForScanning(projectId: UUID, host: String, isDevContainer: Bool) {
		scanContexts[projectId] = ScanContext(
			host: host,
			projShort: String(projectId.uuidString.prefix(8)),
			isDevContainer: isDevContainer
		)
	}

	/// User response to a detection toast. `action` resolves what happens to
	/// the detected remote port.
	func resolveDetection(projectId: UUID, remotePort: Int, action: DetectionAction) {
		pendingDetections[projectId]?.remove(remotePort)
		if pendingDetections[projectId]?.isEmpty == true {
			pendingDetections[projectId] = nil
		}
		switch action {
		case .dismissOnce: break
		case .never, .forwardOnce, .always:
			// These cases are handled by the caller via ProjectStore updates.
			// The manager just drops the pending flag; the caller wires the
			// allow/block list or appends a PortForward.
			break
		}
	}

	enum DetectionAction {
		case forwardOnce   // add PortForward (autoDetected=true)
		case always        // add to allowlist + add PortForward
		case never         // add to blocklist
		case dismissOnce   // toast closed without action, show again next scan
	}

	func teardownEverything() {
		let snapshot = establishedForwards
		establishedForwards.removeAll()
		statuses.removeAll()
		effectiveLocalPorts.removeAll()
		// We don't know the (host, remote, local) triples here — rely on SSH
		// master going down via SSHTunnelManager.teardownAll to orphan them.
		_ = snapshot
	}

	func status(for projectId: UUID, forwardId: UUID) -> Status? {
		statuses[projectId]?[forwardId]
	}

	func effectiveLocal(projectId: UUID, forwardId: UUID) -> Int? {
		effectiveLocalPorts[projectId]?[forwardId]
	}

	// MARK: - Private: sync / establish / teardown

	private func syncAsync(project: Project, host: String, remoteHost: String) async {
		let projectId = project.id
		let wantedIds = Set(project.portForwards.filter { $0.enabled }.map(\.id))
		let currentIds = Set(statuses[projectId]?.keys ?? [:].keys)

		// Teardown disabled / removed forwards
		for id in currentIds.subtracting(wantedIds) {
			if let local = effectiveLocalPorts[projectId]?[id] {
				await cancel(host: host, remoteHost: remoteHost, localPort: local, remotePort: 0)
			}
			establishedForwards.remove(ForwardKey(projectId: projectId, forwardId: id))
			statuses[projectId]?[id] = nil
			effectiveLocalPorts[projectId]?[id] = nil
		}

		// `ssh -O forward` requires an existing ControlMaster. On Belve cold
		// start the master isn't up yet (used to be established lazily by
		// the launcher script when the first terminal pane spawned), so
		// every forward would fail with "Could not connect to server".
		// Block on master establishment first.
		if !wantedIds.isEmpty {
			do {
				try await SSHTunnelManager.shared.ensureControlMaster(host: host)
			} catch {
				NSLog("[Belve][forward] ensureControlMaster failed host=%@ error=%@", host, error.localizedDescription)
				for forward in project.portForwards where forward.enabled {
					statuses[projectId, default: [:]][forward.id] = .error("SSH master unavailable")
				}
				return
			}
		}

		// Establish new ones
		for forward in project.portForwards where forward.enabled {
			let key = ForwardKey(projectId: projectId, forwardId: forward.id)
			if establishedForwards.contains(key) { continue }
			statuses[projectId, default: [:]][forward.id] = .establishing
			let (actualLocal, status) = await establish(
				host: host,
				remoteHost: remoteHost,
				requestedLocal: forward.localPort,
				remotePort: forward.remotePort,
				allowRemap: forward.autoDetected
			)
			statuses[projectId]?[forward.id] = status
			if let actualLocal {
				effectiveLocalPorts[projectId, default: [:]][forward.id] = actualLocal
				establishedForwards.insert(key)
			}
		}
	}

	private func teardownAll(projectId: UUID, host: String) async {
		guard let portMap = effectiveLocalPorts[projectId] else { return }
		for (forwardId, localPort) in portMap {
			await cancel(host: host, remoteHost: "", localPort: localPort, remotePort: 0)
			establishedForwards.remove(ForwardKey(projectId: projectId, forwardId: forwardId))
		}
		statuses[projectId] = nil
		effectiveLocalPorts[projectId] = nil
	}

	/// Run `ssh -O forward -L LPORT:RHOST:RPORT host`. If `allowRemap` and
	/// LPORT is busy locally, probe upwards for a free port (bounded). Returns
	/// the (actualLocalPort, resulting-status).
	private func establish(
		host: String,
		remoteHost: String,
		requestedLocal: Int,
		remotePort: Int,
		allowRemap: Bool
	) async -> (Int?, Status) {
		let chosenLocal: Int
		let status: Status

		if Self.isPortFree(requestedLocal) {
			chosenLocal = requestedLocal
			status = .active
		} else if allowRemap {
			guard let free = Self.findFreePort(startingAt: requestedLocal + 1, maxTries: 50) else {
				return (nil, .conflict)
			}
			chosenLocal = free
			status = .remapped(actualLocal: free)
		} else {
			return (nil, .conflict)
		}

		let ok = await Self.runForward(host: host, local: chosenLocal, remoteHost: remoteHost, remotePort: remotePort)
		if !ok {
			return (nil, .error("ssh -O forward failed"))
		}
		return (chosenLocal, status)
	}

	private func cancel(host: String, remoteHost: String, localPort: Int, remotePort: Int) async {
		await Self.runCancel(host: host, local: localPort)
	}

	// MARK: - Health polling

	private func startHealthTimer() {
		healthTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.updateHealth()
			}
		}
	}

	// MARK: - Remote listening-port scanner

	private func startScanTimer() {
		scanTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in
				await self?.scanAll()
			}
		}
	}

	private func scanAll() async {
		for (projectId, ctx) in scanContexts {
			let current = await Self.scanRemotePorts(ctx: ctx)
			NSLog("[Belve][scan] project=%@ host=%@ devContainer=%@ found=%@",
				String(projectId.uuidString.prefix(8)),
				ctx.host,
				ctx.isDevContainer ? "Y" : "N",
				current.sorted().map(String.init).joined(separator: ","))
			let isFirstScan = lastSeenRemotePorts[projectId] == nil
			let previous = lastSeenRemotePorts[projectId] ?? []
			lastSeenRemotePorts[projectId] = current
			// First scan establishes the baseline — don't toast every pre-existing
			// listening port (the container already has dozens at start).
			if isFirstScan {
				NSLog("[Belve][scan] baseline established for project=%@", String(projectId.uuidString.prefix(8)))
				continue
			}
			guard !current.isEmpty else { continue }
			let newPorts = current.subtracting(previous)
			for port in newPorts {
				NSLog("[Belve][scan] new port detected project=%@ port=%d",
					String(projectId.uuidString.prefix(8)), port)
				handleNewPort(projectId: projectId, port: port)
			}
		}
	}

	private func handleNewPort(projectId: UUID, port: Int) {
		NotificationCenter.default.post(
			name: .belvePortDetected,
			object: nil,
			userInfo: ["projectId": projectId, "port": port]
		)
	}

	/// Called by ProjectStore when it has applied the project-side allow/block
	/// rules and decided whether to surface a toast. The manager owns the
	/// `pendingDetections` presentation state.
	func surfaceDetection(projectId: UUID, port: Int) {
		pendingDetections[projectId, default: []].insert(port)
	}

	private static func scanRemotePorts(ctx: ScanContext) async -> Set<Int> {
		// Return the raw /proc/net/tcp{,6} content and parse on the Mac side —
		// avoids the shell-quoting minefield of embedding awk into an
		// `ssh host docker exec CID sh -c '...'` chain. /proc/net/tcp is
		// available on every Linux regardless of which userland tools (ss,
		// netstat) are installed in the container image.
		let cmd: String
		if ctx.isDevContainer {
			cmd = """
			CID=$(grep -m1 '^CID=' ~/.belve/projects/\(ctx.projShort).env 2>/dev/null | cut -d= -f2 | tr -d '\\n')
			if [ -z "$CID" ]; then exit 0; fi
			docker exec "$CID" cat /proc/net/tcp /proc/net/tcp6 2>/dev/null
			"""
		} else {
			cmd = "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"
		}
		let output = await runSSHWithOutput(host: ctx.host, command: cmd)
		return Self.parseListeningPorts(from: output)
	}

	/// Parse `/proc/net/tcp{,6}` output and return the set of LISTEN ports.
	/// Columns: `sl local_address rem_address st ...`. Local address is
	/// "IPHEX:PORTHEX". State "0A" means LISTEN (TCP_LISTEN).
	static func parseListeningPorts(from output: String) -> Set<Int> {
		var ports: Set<Int> = []
		for line in output.split(whereSeparator: { $0.isNewline }) {
			let cols = line.split(whereSeparator: { $0.isWhitespace })
			guard cols.count >= 4, cols[3] == "0A" else { continue }
			let localAddr = cols[1]
			let parts = localAddr.split(separator: ":")
			guard parts.count == 2,
				  let port = Int(parts[1], radix: 16),
				  port >= 1024,
				  port <= 65535,
				  !systemReservedPorts.contains(port) else { continue }
			ports.insert(port)
		}
		return ports
	}

	private static func runSSHWithOutput(host: String, command: String) async -> String {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .utility).async {
				let proc = Process()
				proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
				proc.arguments = [
					"-o", "ControlPath=\(controlPath(for: host))",
					host,
					command,
				]
				let out = Pipe()
				proc.standardOutput = out
				proc.standardError = FileHandle.nullDevice
				do {
					try proc.run()
					proc.waitUntilExit()
					let data = out.fileHandleForReading.readDataToEndOfFile()
					continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
				} catch {
					continuation.resume(returning: "")
				}
			}
		}
	}

	private func updateHealth() {
		for (projectId, forwards) in statuses {
			for (forwardId, current) in forwards {
				guard let local = effectiveLocalPorts[projectId]?[forwardId] else { continue }
				let reachable = Self.canConnectLocally(port: local)
				// Only mark unreachable from a previously-active state so we
				// don't overwrite conflict / error tracking.
				if case .active = current, !reachable {
					statuses[projectId]?[forwardId] = .unreachable
				} else if case .remapped = current, !reachable {
					statuses[projectId]?[forwardId] = .unreachable
				} else if case .unreachable = current, reachable {
					statuses[projectId]?[forwardId] = .active
				}
			}
		}
	}

	// MARK: - Static helpers

	static func isPortFree(_ port: Int) -> Bool {
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

	static func findFreePort(startingAt: Int, maxTries: Int) -> Int? {
		for candidate in startingAt..<(startingAt + maxTries) where candidate < 65536 {
			if isPortFree(candidate) { return candidate }
		}
		return nil
	}

	/// Non-blocking test: open a TCP connect to 127.0.0.1:port. Returns true
	/// if the port accepts (i.e., something is listening — the ssh forward
	/// itself counts).
	static func canConnectLocally(port: Int) -> Bool {
		let sock = socket(AF_INET, SOCK_STREAM, 0)
		guard sock >= 0 else { return false }
		defer { close(sock) }
		var addr = sockaddr_in()
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = UInt16(port).bigEndian
		addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
		let result = withUnsafePointer(to: &addr) { ptr in
			ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
				Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		return result == 0
	}

	private static func controlPath(for host: String) -> String {
		"/tmp/belve-ssh-ctrl-\(host)"
	}

	@discardableResult
	private static func runForward(host: String, local: Int, remoteHost: String, remotePort: Int) async -> Bool {
		await runSSH(
			host: host,
			args: ["-O", "forward", "-L", "\(local):\(remoteHost):\(remotePort)"]
		)
	}

	@discardableResult
	private static func runCancel(host: String, local: Int) async -> Bool {
		// For -O cancel the remote target doesn't matter — SSH matches on
		// listen-side spec. We pass 127.0.0.1:0 as the spec is required.
		await runSSH(
			host: host,
			args: ["-O", "cancel", "-L", "\(local):127.0.0.1:0"]
		)
	}

	/// Read the container IP from `~/.belve/projects/<short>.env` on the VM.
	/// The file is written by `belve-setup` at DevContainer start and contains
	/// a `CIP=<ipv4>` line. Returns nil if the file is missing or malformed —
	/// caller falls back to 127.0.0.1.
	/// Look up the container IP for a DevContainer project. Reads `CIP=...` from
	/// `~/.belve/projects/<projShort>.env` over SSH (uses the existing
	/// ControlMaster, no fresh handshake). `internal` so SSHTunnelManager /
	/// ProjectStore can reuse without duplicating the SSH call.
	static func fetchContainerIP(host: String, projShort: String) async -> String? {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .utility).async {
				let proc = Process()
				proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
				proc.arguments = [
					"-o", "ControlPath=\(controlPath(for: host))",
					host,
					"grep -m1 '^CIP=' ~/.belve/projects/\(projShort).env 2>/dev/null | cut -d= -f2 | tr -d '\\n'"
				]
				let outPipe = Pipe()
				proc.standardOutput = outPipe
				proc.standardError = FileHandle.nullDevice
				do {
					try proc.run()
					proc.waitUntilExit()
					let data = outPipe.fileHandleForReading.readDataToEndOfFile()
					let str = String(data: data, encoding: .utf8)?
						.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
					if proc.terminationStatus == 0, !str.isEmpty {
						continuation.resume(returning: str)
					} else {
						continuation.resume(returning: nil)
					}
				} catch {
					continuation.resume(returning: nil)
				}
			}
		}
	}

	private static func runSSH(host: String, args: [String]) async -> Bool {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .utility).async {
				let proc = Process()
				proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
				var all = ["-o", "ControlPath=\(controlPath(for: host))"]
				all.append(contentsOf: args)
				all.append(host)
				proc.arguments = all
				proc.standardOutput = FileHandle.nullDevice
				proc.standardError = FileHandle.nullDevice
				do {
					try proc.run()
					proc.waitUntilExit()
					continuation.resume(returning: proc.terminationStatus == 0)
				} catch {
					continuation.resume(returning: false)
				}
			}
		}
	}
}
