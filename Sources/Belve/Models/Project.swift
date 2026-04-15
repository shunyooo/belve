import Foundation

enum Workspace: Codable, Hashable {
	case local(path: String?)
	case ssh(host: String, path: String?)
	case devContainer(host: String, workspace: String)
}

struct Project: Identifiable, Codable, Hashable {
	let id: UUID
	var name: String
	var workspace: Workspace

	init(id: UUID = UUID(), name: String, workspace: Workspace = .local(path: nil)) {
		self.id = id
		self.name = name
		self.workspace = workspace
	}

	/// Create a copy with a new UUID. Forces SwiftUI view recreation when connection type changes.
	func withNewId() -> Project {
		Project(id: UUID(), name: name, workspace: workspace)
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
