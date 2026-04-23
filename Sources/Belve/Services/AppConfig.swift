import Foundation

/// Global app configuration, persisted to ~/Library/Application Support/Belve/config.json
class AppConfig: ObservableObject {
	static let shared = AppConfig()

	@Published var excludePatterns: [String] = [
		".git", "node_modules", ".build", "__pycache__",
		".DS_Store", ".Trash", ".belve"
	]

	/// Sidebar の active session indicator アニメスタイル。
	@Published var spinnerStyle: SpinnerStyle = .pulse {
		didSet { if oldValue != spinnerStyle { save() } }
	}

	private static var configURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("config.json")
	}

	private struct Persisted: Codable {
		var fileTree: FileTreeConfig?
		var ui: UIConfig?

		struct FileTreeConfig: Codable {
			var excludePatterns: [String]?
		}

		struct UIConfig: Codable {
			var spinnerStyle: String?
		}
	}

	init() {
		load()
	}

	private func load() {
		guard let data = try? Data(contentsOf: Self.configURL),
			  let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
		if let patterns = persisted.fileTree?.excludePatterns {
			excludePatterns = patterns
		}
		if let raw = persisted.ui?.spinnerStyle, let style = SpinnerStyle(rawValue: raw) {
			spinnerStyle = style
		}
	}

	func save() {
		let persisted = Persisted(
			fileTree: .init(excludePatterns: excludePatterns),
			ui: .init(spinnerStyle: spinnerStyle.rawValue)
		)
		if let data = try? JSONEncoder().encode(persisted) {
			try? data.write(to: Self.configURL)
		}
	}

	func shouldExclude(_ name: String) -> Bool {
		excludePatterns.contains(name)
	}
}
