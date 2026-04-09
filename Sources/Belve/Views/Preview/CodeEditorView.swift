import SwiftUI
import WebKit

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
	let filename: String
	let content: String
	let onContentChanged: (String) -> Void

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "editorHandler")

		let webView = EditorWebView(frame: .zero, configuration: config)
		webView.identifier = NSUserInterfaceItemIdentifier("BelveEditorWebView:\(projectId.uuidString)")
		webView.setValue(false, forKey: "drawsBackground")
		context.coordinator.webView = webView
		context.coordinator.pendingFile = (filename, content)

		if let html = Self.buildHTML() {
			webView.loadHTMLString(html, baseURL: nil)
		}

		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(onContentChanged: onContentChanged)
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
		var pendingFile: (filename: String, content: String)?
		let onContentChanged: (String) -> Void

		init(onContentChanged: @escaping (String) -> Void) {
			self.onContentChanged = onContentChanged
		}

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
				  let type = body["type"] as? String else { return }

			switch type {
			case "ready":
				if let file = pendingFile {
					openFile(filename: file.filename, content: file.content)
					pendingFile = nil
				}
			case "contentChanged":
				if let content = body["content"] as? String {
					onContentChanged(content)
				}
			default:
				break
			}
		}

		func openFile(filename: String, content: String) {
			let escaped = content
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "`", with: "\\`")
				.replacingOccurrences(of: "$", with: "\\$")
			webView?.evaluateJavaScript("editorOpenFile(`\(escaped)`, `\(filename)`)")
		}
	}
}
