import Foundation

// MARK: - LSP Protocol Types

struct LSPPosition: Codable {
	let line: Int
	let character: Int
}

struct LSPRange: Codable {
	let start: LSPPosition
	let end: LSPPosition
}

struct LSPLocation: Codable {
	let uri: String
	let range: LSPRange
}

struct LSPTextDocumentIdentifier: Codable {
	let uri: String
}

struct LSPTextDocumentPositionParams: Codable {
	let textDocument: LSPTextDocumentIdentifier
	let position: LSPPosition
}

struct LSPHoverResult: Codable {
	let contents: LSPMarkupContent?
	let range: LSPRange?
}

struct LSPMarkupContent: Codable {
	let kind: String // "plaintext" or "markdown"
	let value: String
}

// MARK: - LSP Service Protocol

protocol LSPService: AnyObject {
	var isReady: Bool { get }
	func start(rootPath: String, language: String) async throws
	func stop() async
	func hover(file: String, line: Int, column: Int) async -> String?
	func definition(file: String, line: Int, column: Int) async -> LSPLocation?
	func didOpen(file: String, content: String, languageId: String)
	func didChange(file: String, content: String)
	func didClose(file: String)
}

// MARK: - Local LSP Process

final class LocalLSPProcess: LSPService {
	private var process: Process?
	private var stdin: FileHandle?
	private var stdoutPipe: Pipe?
	private let queue = DispatchQueue(label: "belve.lsp", qos: .userInitiated)
	private var responseHandlers: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]
	private var nextRequestId = 1
	private var buffer = Data()
	private var openDocuments = Set<String>()
	private(set) var isReady = false
	private let language: String
	private var rootUri: String = ""

	init(language: String) {
		self.language = language
	}

	private struct ServerConfig {
		let executable: String
		let args: [String]
		let installCommand: String?
	}

	static func findExecutable(_ name: String) -> String? {
		let searchPaths = [
			"/usr/local/bin",
			"/opt/homebrew/bin",
			"/usr/bin",
			NSHomeDirectory() + "/.local/bin",
			NSHomeDirectory() + "/.npm-global/bin",
			NSHomeDirectory() + "/node_modules/.bin",
		]
		for dir in searchPaths {
			let path = (dir as NSString).appendingPathComponent(name)
			if FileManager.default.fileExists(atPath: path) { return path }
		}
		// which で検索
		let proc = Process()
		let pipe = Pipe()
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
		proc.arguments = [name]
		proc.standardOutput = pipe
		proc.standardError = FileHandle.nullDevice
		try? proc.run()
		proc.waitUntilExit()
		let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return output.isEmpty ? nil : output
	}

	static func installServer(language: String) async throws {
		switch language {
		case "python":
			if findExecutable("pip3") != nil || findExecutable("pip") != nil {
				try await runInstall("pip3 install pyright 2>/dev/null || pip install pyright")
			} else if findExecutable("npm") != nil {
				try await runInstall("npm install -g pyright")
			} else {
				throw LSPError.installFailed("No pip or npm found")
			}
		case "typescript", "javascript":
			guard findExecutable("npm") != nil else {
				throw LSPError.installFailed("npm not found")
			}
			try await runInstall("npm install -g typescript-language-server typescript")
		default:
			throw LSPError.unsupportedLanguage(language)
		}
	}

	private static func runInstall(_ command: String) async throws {
		NSLog("[Belve][LSP] Installing %@...", command)
		let proc = Process()
		let pipe = Pipe()
		proc.executableURL = URL(fileURLWithPath: "/bin/sh")
		proc.arguments = ["-c", command]
		proc.standardOutput = pipe
		proc.standardError = pipe
		try proc.run()
		proc.waitUntilExit()
		let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
		if proc.terminationStatus != 0 {
			NSLog("[Belve][LSP] Install failed: %@", output)
			throw LSPError.installFailed(command)
		}
		NSLog("[Belve][LSP] Install succeeded: %@", command)
	}

	private static func resolveServer(language: String) throws -> ServerConfig {
		switch language {
		case "python":
			guard let path = findExecutable("pyright-langserver") else {
				throw LSPError.serverNotFound("pyright-langserver")
			}
			return ServerConfig(executable: path, args: ["--stdio"], installCommand: nil)
		case "typescript", "javascript":
			guard let path = findExecutable("typescript-language-server") else {
				throw LSPError.serverNotFound("typescript-language-server")
			}
			return ServerConfig(executable: path, args: ["--stdio"], installCommand: nil)
		default:
			throw LSPError.unsupportedLanguage(language)
		}
	}

	func start(rootPath: String, language: String) async throws {
		let config = try Self.resolveServer(language: language)

		rootUri = "file://" + rootPath

		let proc = Process()
		let inPipe = Pipe()
		let outPipe = Pipe()

		proc.executableURL = URL(fileURLWithPath: config.executable)
		proc.arguments = config.args
		proc.standardInput = inPipe
		proc.standardOutput = outPipe
		proc.standardError = FileHandle.nullDevice

		try proc.run()

		self.process = proc
		self.stdin = inPipe.fileHandleForWriting
		self.stdoutPipe = outPipe

		// Start reading stdout
		startReading(outPipe.fileHandleForReading)

		// Initialize
		let initResult = await sendRequest("initialize", params: [
			"processId": ProcessInfo.processInfo.processIdentifier,
			"rootUri": rootUri,
			"capabilities": [
				"textDocument": [
					"hover": ["contentFormat": ["markdown", "plaintext"]],
					"definition": [:] as [String: Any]
				]
			]
		] as [String: Any])

		guard initResult != nil else {
			throw LSPError.initializeFailed
		}

		// Send initialized notification
		sendNotification("initialized", params: [:] as [String: Any])
		isReady = true
		NSLog("[Belve][LSP] %@ server started for %@", language, rootPath)
	}

	func stop() async {
		guard let process, process.isRunning else { return }
		isReady = false

		_ = await sendRequest("shutdown", params: nil)
		sendNotification("exit", params: nil)

		DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
			if self?.process?.isRunning == true {
				self?.process?.terminate()
			}
		}

		openDocuments.removeAll()
		NSLog("[Belve][LSP] %@ server stopped", language)
	}

	func hover(file: String, line: Int, column: Int) async -> String? {
		ensureDocumentOpen(file)
		let params: [String: Any] = [
			"textDocument": ["uri": fileToUri(file)],
			"position": ["line": line - 1, "character": column - 1]
		]
		guard let result = await sendRequest("textDocument/hover", params: params),
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
		guard let result = await sendRequest("textDocument/definition", params: params) else {
			return nil
		}
		// Result can be Location or Location[]
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
		sendNotification("textDocument/didOpen", params: [
			"textDocument": [
				"uri": uri,
				"languageId": languageId,
				"version": 1,
				"text": content
			]
		] as [String: Any])
	}

	func didChange(file: String, content: String) {
		let uri = fileToUri(file)
		sendNotification("textDocument/didChange", params: [
			"textDocument": ["uri": uri, "version": Int(Date().timeIntervalSince1970)],
			"contentChanges": [["text": content]]
		] as [String: Any])
	}

	func didClose(file: String) {
		let uri = fileToUri(file)
		openDocuments.remove(uri)
		sendNotification("textDocument/didClose", params: [
			"textDocument": ["uri": uri]
		] as [String: Any])
	}

	// MARK: - Private

	private func ensureDocumentOpen(_ file: String) {
		let uri = fileToUri(file)
		if !openDocuments.contains(uri) {
			// Read file content and open
			if let content = try? String(contentsOfFile: uriToFile(uri)) {
				let langId = detectLanguageId(file)
				didOpen(file: file, content: content, languageId: langId)
			}
		}
	}

	private func fileToUri(_ path: String) -> String {
		if path.hasPrefix("file://") { return path }
		return "file://" + path
	}

	private func uriToFile(_ uri: String) -> String {
		if uri.hasPrefix("file://") { return String(uri.dropFirst(7)) }
		return uri
	}

	private func detectLanguageId(_ file: String) -> String {
		let ext = (file as NSString).pathExtension.lowercased()
		switch ext {
		case "py": return "python"
		case "ts", "tsx": return "typescript"
		case "js", "jsx": return "javascript"
		case "swift": return "swift"
		case "go": return "go"
		case "rs": return "rust"
		default: return "plaintext"
		}
	}

	private func sendRequest(_ method: String, params: [String: Any]?) async -> [String: Any]? {
		let id = nextRequestId
		nextRequestId += 1

		var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
		if let params { msg["params"] = params }

		return await withCheckedContinuation { continuation in
			queue.async { [weak self] in
				self?.responseHandlers[id] = continuation
				self?.writeMessage(msg)
			}
		}
	}

	private func sendNotification(_ method: String, params: Any?) {
		var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
		if let params { msg["params"] = params }
		queue.async { [weak self] in
			self?.writeMessage(msg)
		}
	}

	private func writeMessage(_ msg: [String: Any]) {
		guard let data = try? JSONSerialization.data(withJSONObject: msg),
			  let stdin else { return }
		let header = "Content-Length: \(data.count)\r\n\r\n"
		var payload = Data(header.utf8)
		payload.append(data)
		stdin.write(payload)
	}

	private func startReading(_ handle: FileHandle) {
		queue.async { [weak self] in
			while true {
				let chunk = handle.availableData
				if chunk.isEmpty { break }
				self?.buffer.append(chunk)
				self?.processBuffer()
			}
		}
	}

	private func processBuffer() {
		while true {
			guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
			let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
			guard let headerStr = String(data: headerData, encoding: .utf8),
				  let lengthLine = headerStr.split(separator: "\r\n").first(where: { $0.hasPrefix("Content-Length:") }),
				  let length = Int(lengthLine.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces))
			else { return }

			let bodyStart = headerEnd.upperBound
			let bodyEnd = buffer.index(bodyStart, offsetBy: length)
			guard bodyEnd <= buffer.endIndex else { return }

			let bodyData = buffer[bodyStart..<bodyEnd]
			buffer.removeSubrange(buffer.startIndex..<bodyEnd)

			if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
				handleMessage(json)
			}
		}
	}

	private func handleMessage(_ msg: [String: Any]) {
		if let id = msg["id"] as? Int, let handler = responseHandlers.removeValue(forKey: id) {
			// Response
			if let result = msg["result"] {
				if let dict = result as? [String: Any] {
					handler.resume(returning: dict)
				} else if let arr = result as? [[String: Any]] {
					handler.resume(returning: ["__array__": arr])
				} else {
					handler.resume(returning: [:])
				}
			} else {
				handler.resume(returning: nil)
			}
		}
		// Notifications (diagnostics etc) — ignored for now
	}
}

enum LSPError: Error {
	case unsupportedLanguage(String)
	case initializeFailed
	case notReady
	case serverNotFound(String)
	case installFailed(String)
}
