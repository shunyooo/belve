import Foundation

enum FileTreePosition: String, Codable, CaseIterable {
	case left
	case right
}

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

	/// Indicator のサイズ (pt)。デフォルト 10。
	@Published var spinnerSize: CGFloat = 10 {
		didSet { if oldValue != spinnerSize { save() } }
	}

	/// MainWindow のメイン表示モード (project / tile)。
	@Published var viewMode: ViewMode = .project {
		didSet { if oldValue != viewMode { save() } }
	}

	/// ファイルツリーの表示位置。
	@Published var fileTreePosition: FileTreePosition = .right {
		didSet { if oldValue != fileTreePosition { save() } }
	}

	/// xterm.js の font size (8-28 pt)。Cmd +/- でユーザー調整可能。
	@Published var terminalFontSize: CGFloat = 13 {
		didSet {
			let clamped = min(max(8, terminalFontSize), 28)
			if clamped != terminalFontSize {
				terminalFontSize = clamped
				return
			}
			if oldValue != terminalFontSize { save() }
		}
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
			var spinnerSize: CGFloat?
			var viewMode: String?
			var terminalFontSize: CGFloat?
			var fileTreePosition: String?
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
		if let size = persisted.ui?.spinnerSize {
			spinnerSize = size
		}
		if let raw = persisted.ui?.viewMode, let mode = ViewMode(rawValue: raw) {
			viewMode = mode
		}
		if let size = persisted.ui?.terminalFontSize {
			terminalFontSize = min(max(8, size), 28)
		}
		if let raw = persisted.ui?.fileTreePosition, let pos = FileTreePosition(rawValue: raw) {
			fileTreePosition = pos
		}
	}

	func save() {
		let persisted = Persisted(
			fileTree: .init(excludePatterns: excludePatterns),
			ui: .init(
				spinnerStyle: spinnerStyle.rawValue,
				spinnerSize: spinnerSize,
				viewMode: viewMode.rawValue,
				terminalFontSize: terminalFontSize,
				fileTreePosition: fileTreePosition.rawValue
			)
		)
		if let data = try? JSONEncoder().encode(persisted) {
			try? data.write(to: Self.configURL)
		}
	}

	func shouldExclude(_ name: String) -> Bool {
		excludePatterns.contains(name)
	}
}
