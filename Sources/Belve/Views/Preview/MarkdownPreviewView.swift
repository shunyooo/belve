import SwiftUI
import WebKit

/// Markdown ファイルの read-only HTML preview。WYSIWYG エディタは normalize 問題で
/// 廃止 (= 2026-04-23 milkdown 撤去)、編集が必要な時は CodeEditorView (CodeMirror)
/// に切り替える二段構え。デフォルトはこの preview。
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
		let webView = WKWebView(frame: .zero, configuration: config)
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
		/// markdown file の dir (相対 image path の base)。JS に渡して解決させる。
		var markdownDir: String = ""
		/// 初回 render 後に store の scroll % を反映するためのフラグ。
		/// content render 完了 → DOM 確定 → setScrollPercent の順で呼ぶ必要があり、
		/// `ready` 時点ではまだ DOM が無いので render 後に投げる。
		private var didApplyInitialScroll = false

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
