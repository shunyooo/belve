import SwiftUI
import WebKit

/// Renders unified diff text as styled HTML in a WKWebView.
struct DiffContentView: View {
	let diffText: String
	let filename: String

	var body: some View {
		DiffWebView(diffText: diffText, filename: filename)
	}
}

private struct DiffWebView: NSViewRepresentable {
	let diffText: String
	let filename: String

	func makeNSView(context: Context) -> WKWebView {
		let webView = WKWebView()
		webView.setValue(false, forKey: "drawsBackground")
		loadDiff(webView)
		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
		loadDiff(nsView)
	}

	private func loadDiff(_ webView: WKWebView) {
		let html = buildHTML(diffText: diffText, filename: filename)
		webView.loadHTMLString(html, baseURL: nil)
	}

	private func buildHTML(diffText: String, filename: String) -> String {
		let lines = diffText.components(separatedBy: "\n")
		var htmlLines = ""
		var oldLine = 0
		var newLine = 0

		for line in lines {
			let escaped = line
				.replacingOccurrences(of: "&", with: "&amp;")
				.replacingOccurrences(of: "<", with: "&lt;")
				.replacingOccurrences(of: ">", with: "&gt;")

			if line.hasPrefix("@@") {
				// Parse hunk header
				let parts = line.components(separatedBy: " ")
				if parts.count >= 3 {
					let oldPart = parts[1].dropFirst()
					let newPart = parts[2].dropFirst()
					let oldComps = oldPart.split(separator: ",")
					let newComps = newPart.split(separator: ",")
					oldLine = Int(oldComps[0]) ?? 0
					newLine = Int(newComps[0]) ?? 0
				}
				htmlLines += "<tr class=\"hunk\"><td class=\"ln\"></td><td class=\"ln\"></td><td class=\"code\">\(escaped)</td></tr>\n"
			} else if line.hasPrefix("---") || line.hasPrefix("+++") {
				htmlLines += "<tr class=\"meta\"><td class=\"ln\"></td><td class=\"ln\"></td><td class=\"code\">\(escaped)</td></tr>\n"
			} else if line.hasPrefix("+") {
				htmlLines += "<tr class=\"add\"><td class=\"ln\"></td><td class=\"ln\">\(newLine)</td><td class=\"code\">\(escaped)</td></tr>\n"
				newLine += 1
			} else if line.hasPrefix("-") {
				htmlLines += "<tr class=\"del\"><td class=\"ln\">\(oldLine)</td><td class=\"ln\"></td><td class=\"code\">\(escaped)</td></tr>\n"
				oldLine += 1
			} else if !line.isEmpty || (oldLine > 0 || newLine > 0) {
				htmlLines += "<tr><td class=\"ln\">\(oldLine)</td><td class=\"ln\">\(newLine)</td><td class=\"code\">\(escaped)</td></tr>\n"
				oldLine += 1
				newLine += 1
			}
		}

		let escapedFilename = filename
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")

		return """
		<!DOCTYPE html>
		<html>
		<head>
		<meta charset="UTF-8">
		<style>
		* { margin: 0; padding: 0; box-sizing: border-box; }
		body {
			background: #1e1e2e;
			color: #cdd6f4;
			font-family: 'SF Mono', Menlo, Monaco, monospace;
			font-size: 12px;
			line-height: 1.5;
		}
		.filename {
			padding: 8px 12px;
			background: #24242e;
			border-bottom: 1px solid #313244;
			font-weight: 600;
			font-size: 11px;
			color: #89b4fa;
		}
		table {
			width: 100%;
			border-collapse: collapse;
		}
		tr { }
		tr.add { background: rgba(166, 227, 161, 0.12); }
		tr.del { background: rgba(243, 139, 168, 0.12); }
		tr.hunk {
			background: rgba(137, 180, 250, 0.08);
			color: #89b4fa;
		}
		tr.meta { color: #585b70; }
		td.ln {
			width: 40px;
			min-width: 40px;
			text-align: right;
			padding: 0 8px;
			color: #585b70;
			user-select: none;
			border-right: 1px solid #313244;
			font-size: 11px;
		}
		td.code {
			padding: 0 12px;
			white-space: pre-wrap;
			word-break: break-all;
		}
		tr.add td.code { color: #a6e3a1; }
		tr.del td.code { color: #f38ba8; }
		.empty {
			display: flex;
			align-items: center;
			justify-content: center;
			height: 100vh;
			color: #585b70;
			font-size: 13px;
		}
		</style>
		</head>
		<body>
		<div class="filename">\(escapedFilename)</div>
		\(htmlLines.isEmpty ? "<div class=\"empty\">No changes</div>" : "<table>\(htmlLines)</table>")
		</body>
		</html>
		"""
	}
}
