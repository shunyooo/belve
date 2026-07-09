import SwiftUI
import WebKit

/// Markdown ファイルの read-only HTML preview。WYSIWYG エディタは normalize 問題で
/// 廃止 (= 2026-04-23 milkdown 撤去)、編集が必要な時は CodeEditorView (CodeMirror)
/// に切り替える二段構え。デフォルトはこの preview。
private final class FindableWebView: WKWebView {
	override var acceptsFirstResponder: Bool { true }

	override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		super.mouseDown(with: event)
	}

	override func performKeyEquivalent(with event: NSEvent) -> Bool {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		if flags == .command, event.charactersIgnoringModifiers == "f" {
			evaluateJavaScript("window.showFindBar && window.showFindBar()", completionHandler: nil)
			return true
		}
		if event.keyCode == 53 { // Escape
			evaluateJavaScript("window.hideFindBar && window.hideFindBar()", completionHandler: nil)
		}
		return super.performKeyEquivalent(with: event)
	}
}

struct MarkdownPreviewView: NSViewRepresentable {
	let content: String
	/// scroll 同期用の file path key。空なら scroll 同期しない (= 旧 caller との互換)。
	var filePath: String = ""
	/// 画像を remote / local から取得するための provider。nil なら画像 scheme を
	/// 登録しない (= 画像は出ないが preview 自体は動く)。
	var provider: (any WorkspaceProvider)?

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "markdownPreviewHandler")
		// `<img>` を belve-img:// scheme 経由で解決する handler を登録。
		if let provider {
			config.setURLSchemeHandler(BelveImageSchemeHandler(provider: provider), forURLScheme: BelveImageSchemeHandler.scheme)
		}
		let webView = FindableWebView(frame: .zero, configuration: config)
		webView.setValue(false, forKey: "drawsBackground")
		// trackpad pinch でズーム可能に (= mermaid 図等の拡大確認用)
		webView.allowsMagnification = true
		webView.magnification = 1.0
		context.coordinator.webView = webView
		context.coordinator.pendingContent = content
		context.coordinator.filePath = filePath
		// markdown file の dir を JS に渡して相対 image path を解決させる。
		context.coordinator.markdownDir = (filePath as NSString).deletingLastPathComponent
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
			nsView.evaluateJavaScript(coord.renderScript(for: content))
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
		var filePath: String = ""
		var markdownDir: String = ""
		private var didApplyInitialScroll = false
		private var findObserver: Any?

		override init() {
			super.init()
			findObserver = NotificationCenter.default.addObserver(
				forName: .belveFindInPreview, object: nil, queue: .main
			) { [weak self] _ in
				guard let webView = self?.webView else { return }
				webView.window?.makeFirstResponder(webView)
				webView.evaluateJavaScript("window.showFindBar && window.showFindBar()") { _, _ in
					webView.evaluateJavaScript("document.getElementById('find-input') && document.getElementById('find-input').focus()", completionHandler: nil)
				}
			}
		}

		deinit {
			if let obs = findObserver {
				NotificationCenter.default.removeObserver(obs)
			}
		}

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
			      let type = body["type"] as? String else { return }
			switch type {
			case "ready":
				isReady = true
				if let pending = pendingContent {
					webView?.evaluateJavaScript(renderScript(for: pending)) { [weak self] _, _ in
						self?.applyInitialScrollIfNeeded()
					}
					lastRendered = pending
					pendingContent = nil
				}
			case "openUrl":
				if let urlString = body["url"] as? String,
				   let url = URL(string: urlString) {
					NSWorkspace.shared.open(url)
				}
			case "scroll":
				if !filePath.isEmpty, let pct = body["percent"] as? Double {
					MarkdownScrollStore.shared.set(CGFloat(pct), for: filePath)
				}
			default:
				break
			}
		}

		/// `window.__belveMarkdownDir` を設定してから markdownRender を呼ぶ JS を生成。
		/// dir は相対 image path 解決の base として renderer.image override が使う。
		func renderScript(for content: String) -> String {
			func esc(_ s: String) -> String {
				s.replacingOccurrences(of: "\\", with: "\\\\")
					.replacingOccurrences(of: "`", with: "\\`")
					.replacingOccurrences(of: "$", with: "\\$")
			}
			return "window.__belveMarkdownDir = `\(esc(markdownDir))`; markdownRender(`\(esc(content))`)"
		}

		private func applyInitialScrollIfNeeded() {
			guard !didApplyInitialScroll, !filePath.isEmpty else { return }
			didApplyInitialScroll = true
			let pct = MarkdownScrollStore.shared.get(for: filePath)
			guard pct > 0 else { return }
			// render 完了直後は layout がまだ確定してない事があるので一拍置いてから。
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
				self?.webView?.evaluateJavaScript("window.setScrollPercent && window.setScrollPercent(\(pct))", completionHandler: nil)
			}
		}
	}
}
