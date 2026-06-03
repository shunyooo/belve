import Foundation

@MainActor
final class LSPManager: ObservableObject {
	static let shared = LSPManager()

	private var services: [String: LSPService] = [:]
	private var activeProjectId: UUID?
	private var activeRootPath: String?
	private var declinedLanguages: Set<String> = []
	private var promptedLanguages: Set<String> = []
	@Published var pendingInstall: (language: String, serverName: String, project: Project)?

	private init() {}

	func activate(project: Project) {
		let projectId = project.id
		if activeProjectId == projectId { return }
		Task { await deactivate() }
		activeProjectId = projectId
		activeRootPath = project.effectivePath
	}

	func deactivate() async {
		for (_, service) in services {
			await service.stop()
		}
		services.removeAll()
		activeProjectId = nil
		activeRootPath = nil
	}

	func hover(file: String, line: Int, column: Int, project: Project) async -> String? {
		guard let service = await serviceFor(file: file, project: project) else { return nil }
		return await service.hover(file: file, line: line, column: column)
	}

	func definition(file: String, line: Int, column: Int, project: Project) async -> LSPLocation? {
		guard let service = await serviceFor(file: file, project: project) else { return nil }
		return await service.definition(file: file, line: line, column: column)
	}

	func didOpen(file: String, content: String, project: Project) {
		let lang = languageForFile(file)
		guard let service = services[lang] else { return }
		service.didOpen(file: file, content: content, languageId: lang)
	}

	func didChange(file: String, content: String, project: Project) {
		let lang = languageForFile(file)
		guard let service = services[lang] else { return }
		service.didChange(file: file, content: content)
	}

	func didClose(file: String, project: Project) {
		let lang = languageForFile(file)
		guard let service = services[lang] else { return }
		service.didClose(file: file)
	}

	// MARK: - Private

	private func serviceFor(file: String, project: Project) async -> LSPService? {
		let lang = languageForFile(file)
		guard isSupportedLanguage(lang) else { return nil }
		guard !declinedLanguages.contains(lang) else { return nil }

		if let existing = services[lang], existing.isReady {
			return existing
		}

		// Remote: LSP via RPC broker in DevContainer
		if project.isRemote {
			let service = RemoteLSPService(projectId: project.id, language: lang)
			do {
				try await service.start(rootPath: project.effectivePath, language: lang)
				services[lang] = service
				return service
			} catch {
				NSLog("[Belve][LSP] Remote %@ server failed: %@", lang, error.localizedDescription)
				if !promptedLanguages.contains(lang) {
					promptedLanguages.insert(lang)
				}
				return nil
			}
		}

		// サーバーが見つかるか確認
		let serverAvailable = LocalLSPProcess.findExecutable(serverName(for: lang)) != nil
		if !serverAvailable {
			// まだ聞いてなければインストール確認を出す
			if !promptedLanguages.contains(lang) {
				promptedLanguages.insert(lang)
				pendingInstall = (language: lang, serverName: serverName(for: lang), project: project)
			}
			return nil
		}

		let service = LocalLSPProcess(language: lang)
		do {
			try await service.start(rootPath: project.effectivePath, language: lang)
			services[lang] = service
			return service
		} catch {
			NSLog("[Belve][LSP] Failed to start %@ server: %@", lang, error.localizedDescription)
			return nil
		}
	}

	func installAndStart(language: String, project: Project) async {
		do {
			try await LocalLSPProcess.installServer(language: language)
			let service = LocalLSPProcess(language: language)
			try await service.start(rootPath: project.effectivePath, language: language)
			services[language] = service
			NSLog("[Belve][LSP] %@ installed and started", language)
		} catch {
			NSLog("[Belve][LSP] Install failed for %@: %@", language, error.localizedDescription)
		}
		pendingInstall = nil
	}

	func declineInstall(language: String) {
		declinedLanguages.insert(language)
		pendingInstall = nil
	}

	private func serverName(for lang: String) -> String {
		switch lang {
		case "python": return "pyright-langserver"
		case "typescript", "javascript": return "typescript-language-server"
		default: return ""
		}
	}

	private func languageForFile(_ file: String) -> String {
		let ext = (file as NSString).pathExtension.lowercased()
		switch ext {
		case "py": return "python"
		case "ts", "tsx": return "typescript"
		case "js", "jsx": return "javascript"
		case "swift": return "swift"
		case "go": return "go"
		case "rs": return "rust"
		default: return "unknown"
		}
	}

	private func isSupportedLanguage(_ lang: String) -> Bool {
		["python", "typescript", "javascript"].contains(lang)
	}
}
