import Foundation

final class RemoteLSPService: LSPService {
	private let projectId: UUID
	private let language: String
	private var lspId: String?
	private var openDocuments = Set<String>()
	private(set) var isReady = false

	init(projectId: UUID, language: String) {
		self.projectId = projectId
		self.language = language
	}

	func start(rootPath: String, language: String) async throws {
		guard let client = RemoteRPCRegistry.shared.client(for: projectId) else {
			throw LSPError.serverNotFound("RPC client not available")
		}
		let res = try await client.send(op: "lspStart", params: [
			"path": rootPath,
			"language": language,
		])
		guard res.ok, let id = res.result?["lspId"] as? String else {
			throw LSPError.initializeFailed
		}
		lspId = id
		isReady = true
		NSLog("[Belve][LSP] Remote %@ server started (id=%@)", language, id)
	}

	func stop() async {
		guard let id = lspId else { return }
		isReady = false
		if let client = RemoteRPCRegistry.shared.client(for: projectId) {
			_ = try? await client.send(op: "lspStop", params: ["lspId": id])
		}
		lspId = nil
		openDocuments.removeAll()
		NSLog("[Belve][LSP] Remote %@ server stopped", language)
	}

	func hover(file: String, line: Int, column: Int) async -> String? {
		ensureDocumentOpen(file)
		let params: [String: Any] = [
			"textDocument": ["uri": fileToUri(file)],
			"position": ["line": line - 1, "character": column - 1]
		]
		guard let result = await sendLspRequest("textDocument/hover", params: params),
			  let contents = result["contents"] as? [String: Any],
			  let value = contents["value"] as? String else {
			return nil
		}
		return value
	}

	func definition(file: String, line: Int, column: Int) async -> LSPLocation? {
		ensureDocumentOpen(file)
		let params: [String: Any] = [
			"textDocument": ["uri": fileToUri(file)],
			"position": ["line": line - 1, "character": column - 1]
		]
		guard let result = await sendLspRequest("textDocument/definition", params: params) else {
			return nil
		}
		// Parse location
		let loc: [String: Any]?
		if let arr = result["__array__"] as? [[String: Any]], let first = arr.first {
			loc = first
		} else if result["uri"] != nil {
			loc = result
		} else {
			return nil
		}
		guard let loc,
			  let uri = loc["uri"] as? String,
			  let range = loc["range"] as? [String: Any],
			  let start = range["start"] as? [String: Any],
			  let line = start["line"] as? Int,
			  let character = start["character"] as? Int else {
			return nil
		}
		return LSPLocation(
			uri: uri,
			range: LSPRange(
				start: LSPPosition(line: line, character: character),
				end: LSPPosition(line: line, character: character)
			)
		)
	}

	func didOpen(file: String, content: String, languageId: String) {
		let uri = fileToUri(file)
		guard !openDocuments.contains(uri) else { return }
		openDocuments.insert(uri)
		let params: [String: Any] = [
			"textDocument": [
				"uri": uri,
				"languageId": languageId,
				"version": 1,
				"text": content
			]
		]
		Task { await sendLspNotification("textDocument/didOpen", params: params) }
	}

	func didChange(file: String, content: String) {
		let uri = fileToUri(file)
		let params: [String: Any] = [
			"textDocument": ["uri": uri, "version": Int(Date().timeIntervalSince1970)],
			"contentChanges": [["text": content]]
		]
		Task { await sendLspNotification("textDocument/didChange", params: params) }
	}

	func didClose(file: String) {
		let uri = fileToUri(file)
		openDocuments.remove(uri)
		let params: [String: Any] = ["textDocument": ["uri": uri]]
		Task { await sendLspNotification("textDocument/didClose", params: params) }
	}

	// MARK: - Private

	private func ensureDocumentOpen(_ file: String) {
		let uri = fileToUri(file)
		if !openDocuments.contains(uri) {
			openDocuments.insert(uri)
			let ext = (file as NSString).pathExtension.lowercased()
			let langId: String
			switch ext {
			case "py": langId = "python"
			case "ts", "tsx": langId = "typescript"
			case "js", "jsx": langId = "javascript"
			default: langId = "plaintext"
			}
			// Read file content via RPC and send didOpen
			Task {
				if let client = RemoteRPCRegistry.shared.client(for: projectId) {
					let res = try? await client.send(op: "read", params: ["path": file])
					if let content = res?.result?["content"] as? String {
						let params: [String: Any] = [
							"textDocument": ["uri": uri, "languageId": langId, "version": 1, "text": content]
						]
						await sendLspNotification("textDocument/didOpen", params: params)
					}
				}
			}
		}
	}

	private func sendLspRequest(_ method: String, params: [String: Any]) async -> [String: Any]? {
		guard let id = lspId, let client = RemoteRPCRegistry.shared.client(for: projectId) else { return nil }
		let paramsJSON: String
		if let data = try? JSONSerialization.data(withJSONObject: params),
		   let str = String(data: data, encoding: .utf8) {
			paramsJSON = str
		} else {
			return nil
		}
		guard let res = try? await client.send(op: "lspRequest", params: [
			"lspId": id,
			"method": method,
			"params": paramsJSON,
		]), res.ok else { return nil }

		// Result comes as a JSON string in result.result
		guard let resultStr = res.result?["result"] as? String,
			  let resultData = resultStr.data(using: .utf8) else { return nil }
		if let dict = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
			return dict
		}
		if let arr = try? JSONSerialization.jsonObject(with: resultData) as? [[String: Any]] {
			return ["__array__": arr]
		}
		return nil
	}

	private func sendLspNotification(_ method: String, params: [String: Any]) async {
		guard let id = lspId, let client = RemoteRPCRegistry.shared.client(for: projectId) else { return }
		let paramsJSON: String
		if let data = try? JSONSerialization.data(withJSONObject: params),
		   let str = String(data: data, encoding: .utf8) {
			paramsJSON = str
		} else {
			return
		}
		_ = try? await client.send(op: "lspRequest", params: [
			"lspId": id,
			"method": method,
			"params": paramsJSON,
		])
	}

	private func fileToUri(_ path: String) -> String {
		if path.hasPrefix("file://") { return path }
		return "file://" + path
	}
}
