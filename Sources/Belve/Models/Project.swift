import Foundation

enum Workspace: Codable, Hashable {
	case local(path: String?)
	case ssh(host: String, path: String?)
	case devContainer(host: String, workspace: String)
}

struct PortForward: Codable, Hashable, Identifiable {
	let id: UUID
	var localPort: Int
	var remotePort: Int
	var enabled: Bool
	/// true if created by auto-detect (remote listening-port scanner). Purely
	/// informational — doesn't change behaviour.
	var autoDetected: Bool

	init(id: UUID = UUID(), localPort: Int, remotePort: Int, enabled: Bool = true, autoDetected: Bool = false) {
		self.id = id
		self.localPort = localPort
		self.remotePort = remotePort
		self.enabled = enabled
		self.autoDetected = autoDetected
	}
}

struct Project: Identifiable, Codable, Hashable {
	let id: UUID
	var name: String
	var workspace: Workspace
	/// Pinned projects are the "currently-active" set — Cmd+[/] cycles only
	/// through pinned projects when any are pinned.
	var isPinned: Bool = false
	/// Optional user-defined group name. Projects sharing the same groupName
	/// render together under a collapsible header in the sidebar. Pinned
	/// projects always appear in the implicit "Pinned" section regardless of
	/// groupName — when unpinned they return to their named group.
	var groupName: String?
	/// User-configured TCP port forwards (local → remote). Manual entries plus
	/// anything the user chose "Always forward" on from the auto-detect toast.
	var portForwards: [PortForward] = []
	/// Auto-detected remote listening ports that the user explicitly dismissed
	/// ("Never forward"). Keeps the detection toast from re-appearing for the
	/// same port on every poll.
	var portForwardBlocklist: Set<Int> = []
	/// Remote ports the user has chosen "Always forward" on — they bypass the
	/// toast and are silently added as auto-detected entries on first sight.
	var portForwardAllowlist: Set<Int> = []

	init(id: UUID = UUID(), name: String, workspace: Workspace = .local(path: nil), isPinned: Bool = false, groupName: String? = nil) {
		self.id = id
		self.name = name
		self.workspace = workspace
		self.isPinned = isPinned
		self.groupName = groupName
	}

	enum CodingKeys: String, CodingKey {
		case id, name, workspace, isPinned, groupName, portForwards, portForwardBlocklist, portForwardAllowlist
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(UUID.self, forKey: .id)
		name = try c.decode(String.self, forKey: .name)
		workspace = try c.decode(Workspace.self, forKey: .workspace)
		isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
		groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
		portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
		portForwardBlocklist = try c.decodeIfPresent(Set<Int>.self, forKey: .portForwardBlocklist) ?? []
		portForwardAllowlist = try c.decodeIfPresent(Set<Int>.self, forKey: .portForwardAllowlist) ?? []
	}

	/// Create a copy with a new UUID. Forces SwiftUI view recreation when connection type changes.
	func withNewId() -> Project {
		var copy = Project(id: UUID(), name: name, workspace: workspace, isPinned: isPinned, groupName: groupName)
		copy.portForwards = portForwards
		copy.portForwardBlocklist = portForwardBlocklist
		copy.portForwardAllowlist = portForwardAllowlist
		return copy
	}

	// MARK: - Convenience computed properties

	var sshHost: String? {
		switch workspace {
		case .ssh(let host, _), .devContainer(let host, _): return host
		case .local: return nil
		}
	}

	/// The path associated with this workspace (folder path for local/SSH, workspace for DevContainer)
	var path: String? {
		switch workspace {
		case .local(let p): return p
		case .ssh(_, let p): return p
		case .devContainer(_, let ws): return ws
		}
	}

	var isDevContainer: Bool {
		if case .devContainer = workspace { return true }
		return false
	}

	var isRemote: Bool {
		switch workspace {
		case .local: return false
		case .ssh, .devContainer: return true
		}
	}

	/// The effective working directory for this project.
	var effectivePath: String {
		switch workspace {
		case .local(let p): return p ?? NSHomeDirectory()
		case .ssh(_, let p): return p ?? "~"
		case .devContainer: return "."
		}
	}

	/// Short identifier for the SSH host (first component of hostname)
	var shortHost: String? {
		sshHost.map { $0.components(separatedBy: ".").first ?? $0 }
	}

	/// Provider for workspace operations (file, git, search, etc.)
	var provider: any WorkspaceProvider {
		switch workspace {
		case .local(let path):
			return LocalProvider(path: path)
		case .ssh(let host, let path):
			return SSHProvider(host: host, path: path)
		case .devContainer(let host, let ws):
			return DevContainerProvider(host: host, workspace: ws)
		}
	}
}
