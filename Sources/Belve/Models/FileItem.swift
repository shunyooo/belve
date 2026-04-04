import Foundation

struct FileItem: Identifiable, Hashable {
	let id = UUID()
	let name: String
	let path: String
	let isDirectory: Bool

	func hash(into hasher: inout Hasher) {
		hasher.combine(path)
	}

	static func == (lhs: FileItem, rhs: FileItem) -> Bool {
		lhs.path == rhs.path
	}
}
