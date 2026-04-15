import SwiftUI
import WebKit

struct EditorDefinitionRequest {
	let symbol: String
	let filename: String
	let language: String
	let line: Int
	let column: Int
}

final class EditorWebView: WKWebView {
	override var acceptsFirstResponder: Bool { true }

	override func performKeyEquivalent(with event: NSEvent) -> Bool {
		guard let firstResponder = window?.firstResponder as? NSView,
			  firstResponder === self || firstResponder.isDescendant(of: self) || isAncestor(of: firstResponder)
		else {
			return super.performKeyEquivalent(with: event)
		}

		return super.performKeyEquivalent(with: event)
	}

	override func flagsChanged(with event: NSEvent) {
		super.flagsChanged(with: event)
		let metaPressed = event.modifierFlags.contains(.command)
		evaluateJavaScript("window.editorSetMetaPressed(\(metaPressed ? "true" : "false"))", completionHandler: nil)
	}

	private func isAncestor(of view: NSView?) -> Bool {
		guard let view else { return false }
		var current: NSView? = view
		while let c = current {
			if c === self { return true }
			current = c.superview
		}
		return false
	}
}

struct CodeEditorView: NSViewRepresentable {
	let projectId: UUID
	let project: Project
	let filename: String
	let content: String
	let line: Int?
	let column: Int?
	let onDefinitionRequest: (EditorDefinitionRequest) -> Void
	let onDefinitionHoverRequest: (EditorDefinitionRequest, @escaping (Bool) -> Void) -> Void
	let onContentChanged: (String) -> Void

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "editorHandler")

		let webView = EditorWebView(frame: .zero, configuration: config)
		webView.identifier = NSUserInterfaceItemIdentifier("BelveEditorWebView:\(projectId.uuidString)")
		webView.setValue(false, forKey: "drawsBackground")
		context.coordinator.webView = webView
		context.coordinator.pendingFile = (filename, content, line, column)

		if let html = Self.buildHTML() {
			webView.loadHTMLString(html, baseURL: nil)
		}

		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
		context.coordinator.project = project
		context.coordinator.openFile(filename: filename, content: content, line: line, column: column)
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(
			onContentChanged: onContentChanged,
			onDefinitionRequest: onDefinitionRequest,
			onDefinitionHoverRequest: onDefinitionHoverRequest
		)
	}

	static func buildHTML() -> String? {
		let execDir = Bundle.main.executableURL!.deletingLastPathComponent()
		let bundlePath = execDir.appendingPathComponent("Belve_Belve.bundle/Contents/Resources/Resources")
		let fallbackPath = execDir
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Sources/Belve/Resources")

		let resourceDir = FileManager.default.fileExists(atPath: bundlePath.path) ? bundlePath : fallbackPath

		guard let htmlTemplate = try? String(contentsOf: resourceDir.appendingPathComponent("editor.html")),
			  let js = try? String(contentsOf: resourceDir.appendingPathComponent("editor-bundle.js"))
		else {
			NSLog("[Belve] Failed to load editor resources")
			return nil
		}

		return htmlTemplate.replacingOccurrences(of: "/* EDITOR_JS */", with: js)
	}

	class Coordinator: NSObject, WKScriptMessageHandler {
		weak var webView: WKWebView?
		var project: Project?
		var pendingFile: (filename: String, content: String, line: Int?, column: Int?)?
		var isReady = false
		private var lastOpenedFile: (filename: String, content: String, line: Int?, column: Int?)?
		let onContentChanged: (String) -> Void
		let onDefinitionRequest: (EditorDefinitionRequest) -> Void
		let onDefinitionHoverRequest: (EditorDefinitionRequest, @escaping (Bool) -> Void) -> Void

		init(
			onContentChanged: @escaping (String) -> Void,
			onDefinitionRequest: @escaping (EditorDefinitionRequest) -> Void,
			onDefinitionHoverRequest: @escaping (EditorDefinitionRequest, @escaping (Bool) -> Void) -> Void
		) {
			self.onContentChanged = onContentChanged
			self.onDefinitionRequest = onDefinitionRequest
			self.onDefinitionHoverRequest = onDefinitionHoverRequest
		}

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
				  let type = body["type"] as? String else { return }

			switch type {
			case "ready":
				isReady = true
				if let file = pendingFile {
					openFile(filename: file.filename, content: file.content, line: file.line, column: file.column)
					pendingFile = nil
				}
			case "contentChanged":
				if let content = body["content"] as? String {
					onContentChanged(content)
				}
			case "definitionRequest":
				guard let symbol = body["symbol"] as? String,
					  let filename = body["filename"] as? String,
					  let language = body["language"] as? String,
					  let line = body["line"] as? Int,
					  let column = body["column"] as? Int else { return }
				onDefinitionRequest(
					EditorDefinitionRequest(
						symbol: symbol,
						filename: filename,
						language: language,
						line: line,
						column: column
					)
				)
			case "definitionHoverRequest":
				guard let requestId = body["requestId"] as? Int,
					  let symbol = body["symbol"] as? String,
					  let filename = body["filename"] as? String,
					  let language = body["language"] as? String,
					  let line = body["line"] as? Int,
					  let column = body["column"] as? Int else { return }
				onDefinitionHoverRequest(
					EditorDefinitionRequest(
						symbol: symbol,
						filename: filename,
						language: language,
						line: line,
						column: column
					)
				) { [weak self] canJump in
					DispatchQueue.main.async {
						self?.webView?.evaluateJavaScript(
							"window.editorSetJumpHoverResult(\(requestId), \(canJump ? "true" : "false"))",
							completionHandler: nil
						)
					}
				}
			default:
				break
			}
		}

		func openFile(filename: String, content: String, line: Int?, column: Int?) {
			let fileState = (filename, content, line, column)
			guard isReady else {
				pendingFile = fileState
				return
			}
			if let lastOpenedFile, lastOpenedFile == fileState {
				return
			}
			lastOpenedFile = fileState
			let escaped = content
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "`", with: "\\`")
				.replacingOccurrences(of: "$", with: "\\$")
			let escapedFilename = filename
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "`", with: "\\`")
				.replacingOccurrences(of: "$", with: "\\$")
			let lineArgument = line.map(String.init) ?? "null"
			let columnArgument = column.map(String.init) ?? "null"
			let script = "editorOpenFile(`\(escaped)`, `\(escapedFilename)`, \(lineArgument), \(columnArgument))"
			webView?.evaluateJavaScript(script, completionHandler: nil)

			// Load diff markers in background
			if let project {
				let filePath = filename
				DispatchQueue.global(qos: .userInitiated).async { [weak self] in
					let rootPath = project.effectivePath
					let relativePath = filePath.hasPrefix(rootPath) ?
						String(filePath.dropFirst(rootPath.count).drop(while: { $0 == "/" })) : filePath
					let hunks = project.provider.gitDiffHunks(rootPath, file: relativePath)
					guard !hunks.isEmpty else { return }
					var markers: [[String: Any]] = []
					for hunk in hunks {
						if hunk.oldCount == 0 {
							// Pure addition
							markers.append(["from": hunk.newStart, "to": hunk.newStart + max(1, hunk.newCount) - 1, "type": "add"])
						} else if hunk.newCount == 0 {
							// Pure deletion — mark the line before
							markers.append(["from": max(1, hunk.newStart), "to": max(1, hunk.newStart), "type": "delete"])
						} else {
							// Modification
							markers.append(["from": hunk.newStart, "to": hunk.newStart + hunk.newCount - 1, "type": "modify"])
						}
					}
					if let json = try? JSONSerialization.data(withJSONObject: markers),
					   let jsonStr = String(data: json, encoding: .utf8) {
						DispatchQueue.main.async {
							self?.webView?.evaluateJavaScript("window.editorSetDiffMarkers(\(jsonStr))", completionHandler: nil)
						}
					}
				}
			}
		}
	}
}
