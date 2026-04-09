import SwiftUI
import WebKit

struct MarkdownEditorView: NSViewRepresentable {
	let projectId: UUID
	let content: String
	let onContentChanged: (String) -> Void

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "markdownHandler")

		let webView = EditorWebView(frame: .zero, configuration: config)
		webView.identifier = NSUserInterfaceItemIdentifier("BelveEditorWebView:\(projectId.uuidString)")
		webView.setValue(false, forKey: "drawsBackground")
		context.coordinator.webView = webView
		context.coordinator.pendingContent = content

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

		guard let htmlTemplate = try? String(contentsOf: resourceDir.appendingPathComponent("markdown.html")),
			  let js = try? String(contentsOf: resourceDir.appendingPathComponent("markdown-bundle.js")),
			  let css = try? String(contentsOf: resourceDir.appendingPathComponent("markdown-bundle.css"))
		else {
			NSLog("[Belve] Failed to load markdown resources")
			return nil
		}

		var html = htmlTemplate
		html = html.replacingOccurrences(of: "/* MARKDOWN_CSS */", with: css)
		html = html.replacingOccurrences(of: "/* MARKDOWN_JS */", with: js)
		return html
	}

	class Coordinator: NSObject, WKScriptMessageHandler {
		weak var webView: WKWebView?
		var pendingContent: String?
		let onContentChanged: (String) -> Void

		init(onContentChanged: @escaping (String) -> Void) {
			self.onContentChanged = onContentChanged
		}

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
				  let type = body["type"] as? String else { return }

			switch type {
			case "ready":
				if let content = pendingContent {
					let escaped = content
						.replacingOccurrences(of: "\\", with: "\\\\")
						.replacingOccurrences(of: "`", with: "\\`")
						.replacingOccurrences(of: "$", with: "\\$")
					webView?.evaluateJavaScript("markdownOpen(`\(escaped)`)")
					pendingContent = nil
				}
			case "contentChanged":
				if let content = body["content"] as? String {
					onContentChanged(content)
				}
			default:
				break
			}
		}
	}
}
