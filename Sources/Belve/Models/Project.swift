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
	var containerImageName: String? // e.g. "mcr.microsoft.com/devcontainers/python:3.12"

	init(id: UUID = UUID(), name: String, sshHost: String? = nil, remotePath: String? = nil, devContainerPath: String? = nil, containerImageName: String? = nil) {
		self.id = id
		self.name = name
		self.sshHost = sshHost
		self.remotePath = remotePath
		self.devContainerPath = devContainerPath
		self.containerImageName = containerImageName
	}

	/// Create a copy with a new UUID. Forces SwiftUI view recreation when connection type changes.
	func withNewId() -> Project {
		Project(id: UUID(), name: name, sshHost: sshHost, remotePath: remotePath, devContainerPath: devContainerPath)
	}

	var isDevContainer: Bool {
		devContainerPath != nil && sshHost != nil
	}

	var isRemote: Bool {
		sshHost != nil
	}

	/// The execution context for this project — determines where commands run.
	var executionContext: ExecutionContext {
		if let sshHost, let devContainerPath {
			return .devContainer(host: sshHost, workspacePath: devContainerPath)
		} else if let sshHost {
			return .ssh(host: sshHost)
		}
		return .local
	}

	/// The effective working directory for this project.
	var effectivePath: String {
		if isDevContainer {
			return "."  // devcontainer exec starts in workspace dir
		}
		return remotePath ?? executionContext.homeDirectory
	}
}
