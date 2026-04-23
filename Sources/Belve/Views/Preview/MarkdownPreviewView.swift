import SwiftUI
import WebKit

/// Markdown ファイルの read-only HTML preview。WYSIWYG エディタは normalize 問題で
/// 廃止 (= 2026-04-23 milkdown 撤去)、編集が必要な時は CodeEditorView (CodeMirror)
/// に切り替える二段構え。デフォルトはこの preview。
struct MarkdownPreviewView: NSViewRepresentable {
	let content: String

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "markdownPreviewHandler")
		let webView = WKWebView(frame: .zero, configuration: config)
		webView.setValue(false, forKey: "drawsBackground")
		context.coordinator.webView = webView
		context.coordinator.pendingContent = content
		if let html = Self.buildHTML() {
			webView.loadHTMLString(html, baseURL: nil)
		}
		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
		// 外部編集 / open 時の content 変更を WebView へ反映。
		let coord = context.coordinator
		if coord.lastRendered == content { return }
		coord.lastRendered = content
		if coord.isReady {
			let escaped = content
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "`", with: "\\`")
				.replacingOccurrences(of: "$", with: "\\$")
			nsView.evaluateJavaScript("markdownRender(`\(escaped)`)")
		} else {
			coord.pendingContent = content
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	static func buildHTML() -> String? {
		let execDir = Bundle.main.executableURL!.deletingLastPathComponent()
		let bundlePath = execDir.appendingPathComponent("Belve_Belve.bundle/Contents/Resources/Resources")
		let fallbackPath = execDir
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Sources/Belve/Resources")
		let resourceDir = FileManager.default.fileExists(atPath: bundlePath.path) ? bundlePath : fallbackPath
		guard let htmlTemplate = try? String(contentsOf: resourceDir.appendingPathComponent("markdown-preview.html")),
		      let js = try? String(contentsOf: resourceDir.appendingPathComponent("markdown-preview-bundle.js"))
		else {
			NSLog("[Belve] Failed to load markdown-preview resources")
			return nil
		}
		return htmlTemplate.replacingOccurrences(of: "/* MARKDOWN_PREVIEW_JS */", with: js)
	}

	class Coordinator: NSObject, WKScriptMessageHandler {
		weak var webView: WKWebView?
		var pendingContent: String?
		var isReady = false
		var lastRendered: String?

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
			      let type = body["type"] as? String else { return }
			switch type {
			case "ready":
				isReady = true
				if let pending = pendingContent {
					let escaped = pending
						.replacingOccurrences(of: "\\", with: "\\\\")
						.replacingOccurrences(of: "`", with: "\\`")
						.replacingOccurrences(of: "$", with: "\\$")
					webView?.evaluateJavaScript("markdownRender(`\(escaped)`)")
					lastRendered = pending
					pendingContent = nil
				}
			case "openUrl":
				if let urlString = body["url"] as? String,
				   let url = URL(string: urlString) {
					NSWorkspace.shared.open(url)
				}
			default:
				break
			}
		}
	}
}
