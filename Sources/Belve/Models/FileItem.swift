import Foundation

struct FileItem: Identifiable, Hashable {
	let id = UUID()
	let name: String
	let path: String
	let isDirectory: Bool
	/// For compact folder display: "Models/Sub" instead of just "Models"
	var compactName: String?

	var displayName: String { compactName ?? name }

	func hash(into hasher: inout Hasher) {
		hasher.combine(path)
	}

	static func == (lhs: FileItem, rhs: FileItem) -> Bool {
		lhs.path == rhs.path
	}
}
