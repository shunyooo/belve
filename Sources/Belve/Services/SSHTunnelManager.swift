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

	/// host → projectId → local port
	private var tunnels: [String: [UUID: Int]] = [:]
	private var allocatedPorts: Set<Int> = []
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

	/// Tear down the forward for a specific (host, project). Runs `ssh -O cancel` off the
	/// main thread. Safe to call even if no tunnel is registered.
	func teardownTunnel(host: String, projectId: UUID) {
		stateLock.lock()
		guard let port = tunnels[host]?[projectId] else {
			stateLock.unlock()
			return
		}
		tunnels[host]?[projectId] = nil
		if tunnels[host]?.isEmpty == true {
			tunnels[host] = nil
		}
		allocatedPorts.remove(port)
		stateLock.unlock()

		DispatchQueue.global(qos: .utility).async {
			Self.cancelForward(host: host, projectId: projectId, localPort: port)
			NSLog("[Belve][tunnel] closed host=%@ project=%@ port=%d",
				  host, String(projectId.uuidString.prefix(8)), port)
		}
	}

	/// Tear down all forwards (app exit or stale cleanup). Blocks until each cancel completes.
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
		NSLog("[Belve][tunnel] teardownAll done")
	}

	// MARK: - Helpers

	/// Path must match the launcher's `BELVE_SSH_CONTROL` so both share one ControlMaster.
	private static func controlPath(for host: String) -> String {
		"/tmp/belve-ssh-ctrl-\(host)"
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

		var errorDescription: String? {
			switch self {
			case .noPortAvailable:
				return "No local port available in range 19222-19322"
			}
		}
	}
}
