import Foundation

enum FileTreePosition: String, Codable, CaseIterable {
	case left
	case right
}

/// SSH channel 多重化 (yamux) のオプトイン設定。
/// `enabled=true` で全 host が新 path、それ以外は `hosts` に列挙された host だけ
/// 新 path。設計詳細は docs/notes/2026-06-24-yamux-multiplex.md。
struct MuxConfig: Codable, Equatable {
	var enabled: Bool = false
	var hosts: [String] = []
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

	/// SSH channel 多重化 (yamux) のオプトイン設定。Phase 6 ロールアウト用。
	/// 環境変数 `BELVE_USE_MUX=1` で常時有効化、`=0` で常時無効化が可能 (= 開発時の試行用)。
	@Published var mux: MuxConfig = MuxConfig() {
		didSet { if oldValue != mux { save() } }
	}

	/// 指定 host で mux 経路を使うべきかの判定。env > enabled > hosts の順で評価。
	func muxEnabled(forHost host: String) -> Bool {
		if let env = ProcessInfo.processInfo.environment["BELVE_USE_MUX"] {
			if env == "1" || env.lowercased() == "true" { return true }
			if env == "0" || env.lowercased() == "false" { return false }
		}
		if mux.enabled { return true }
		return mux.hosts.contains(host)
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
		var mux: MuxConfig?

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
		if let muxCfg = persisted.mux {
			mux = muxCfg
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
			),
			mux: mux
		)
		if let data = try? JSONEncoder().encode(persisted) {
			try? data.write(to: Self.configURL)
		}
	}

	func shouldExclude(_ name: String) -> Bool {
		excludePatterns.contains(name)
	}
}
