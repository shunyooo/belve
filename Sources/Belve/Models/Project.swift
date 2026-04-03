import Foundation

struct Project: Identifiable, Codable, Hashable {
	let id: UUID
	var name: String
	var sshHost: String?
	var remotePath: String?

	init(id: UUID = UUID(), name: String, sshHost: String? = nil, remotePath: String? = nil) {
		self.id = id
		self.name = name
		self.sshHost = sshHost
		self.remotePath = remotePath
	}
}
