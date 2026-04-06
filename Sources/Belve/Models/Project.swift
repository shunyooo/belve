import Foundation

enum ConnectionType: Codable, Hashable {
	case local
	case ssh(host: String)
	case devContainer(host: String, workspacePath: String)
}

struct Project: Identifiable, Codable, Hashable {
	let id: UUID
	var name: String
	var sshHost: String?
	var remotePath: String?
	var devContainerPath: String? // workspace path for devcontainer

	init(id: UUID = UUID(), name: String, sshHost: String? = nil, remotePath: String? = nil, devContainerPath: String? = nil) {
		self.id = id
		self.name = name
		self.sshHost = sshHost
		self.remotePath = remotePath
		self.devContainerPath = devContainerPath
	}

	var isDevContainer: Bool {
		devContainerPath != nil && sshHost != nil
	}

	var isRemote: Bool {
		sshHost != nil
	}

	/// The effective working directory for this project.
	/// Remote projects default to ~, local projects default to user home.
	var effectivePath: String {
		remotePath ?? (isRemote ? "~" : NSHomeDirectory())
	}
}
