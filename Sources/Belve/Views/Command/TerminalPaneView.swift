import SwiftUI
import WebKit

struct TerminalPaneView: NSViewRepresentable {
	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "terminalHandler")

		let webView = WKWebView(frame: .zero, configuration: config)
		webView.setValue(false, forKey: "drawsBackground")
		context.coordinator.webView = webView

		if let html = context.coordinator.buildHTML() {
			webView.loadHTMLString(html, baseURL: nil)
		}

		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	class Coordinator: NSObject, WKScriptMessageHandler {
		weak var webView: WKWebView?
		private var masterFd: Int32 = -1
		private var readSource: DispatchSourceRead?

		func buildHTML() -> String? {
			// Find resources relative to executable
			let execDir = Bundle.main.executableURL!.deletingLastPathComponent()

			// SPM puts resources in Belve_Belve.bundle
			let bundlePath = execDir.appendingPathComponent("Belve_Belve.bundle/Contents/Resources/Resources")
			let fallbackPath = execDir
				.deletingLastPathComponent()
				.deletingLastPathComponent()
				.deletingLastPathComponent()
				.appendingPathComponent("Sources/Belve/Resources")

			let resourceDir: URL
			if FileManager.default.fileExists(atPath: bundlePath.path) {
				resourceDir = bundlePath
			} else {
				resourceDir = fallbackPath
			}

			guard let htmlTemplate = try? String(contentsOf: resourceDir.appendingPathComponent("terminal.html")),
				  let js = try? String(contentsOf: resourceDir.appendingPathComponent("terminal-bundle.js")),
				  let css = try? String(contentsOf: resourceDir.appendingPathComponent("terminal.css"))
			else {
				NSLog("[Belve] Failed to load terminal resources from \(resourceDir.path)")
				return nil
			}

			var html = htmlTemplate
			html = html.replacingOccurrences(of: "/* injected at runtime */</style>\n</head>", with: "\(css)</style>\n</head>")
			html = html.replacingOccurrences(of: "/* injected at runtime */</script>", with: "\(js)</script>")
			return html
		}

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
				  let type = body["type"] as? String else { return }

			switch type {
			case "ready":
				startPTY()
			case "input":
				if let data = body["data"] as? String,
				   let bytes = data.data(using: .utf8) {
					bytes.withUnsafeBytes { ptr in
						let _ = write(masterFd, ptr.baseAddress!, ptr.count)
					}
				}
			case "resize":
				if let cols = body["cols"] as? Int,
				   let rows = body["rows"] as? Int {
					var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
					let _ = ioctl(masterFd, TIOCSWINSZ, &size)
				}
			default:
				break
			}
		}

		private func startPTY() {
			var master: Int32 = 0
			var slave: Int32 = 0

			guard openpty(&master, &slave, nil, nil, nil) == 0 else {
				NSLog("[Belve] Failed to openpty")
				return
			}
			self.masterFd = master

			// posix_spawn with file actions
			var fileActions: posix_spawn_file_actions_t?
			posix_spawn_file_actions_init(&fileActions)
			posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
			posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
			posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
			posix_spawn_file_actions_addclose(&fileActions, master)

			let home = NSHomeDirectory()
			let envStrings = [
				"HOME=\(home)",
				"TERM=xterm-256color",
				"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
				"LANG=en_US.UTF-8",
			]

			// Convert to C strings
			let cEnv = envStrings.map { strdup($0) } + [nil]
			let cArgs = [strdup("/bin/zsh"), strdup("-l"), nil]

			var pid: pid_t = 0
			let result = cArgs.withUnsafeBufferPointer { argsPtr in
				cEnv.withUnsafeBufferPointer { envPtr in
					posix_spawn(
						&pid, "/bin/zsh", &fileActions, nil,
						UnsafeMutablePointer(mutating: argsPtr.baseAddress!),
						UnsafeMutablePointer(mutating: envPtr.baseAddress!)
					)
				}
			}

			// Free C strings
			cArgs.forEach { if let p = $0 { free(p) } }
			cEnv.forEach { if let p = $0 { free(p) } }
			posix_spawn_file_actions_destroy(&fileActions)
			close(slave)

			if result != 0 {
				NSLog("[Belve] posix_spawn failed: \(result)")
				return
			}

			// Read from PTY → WebView
			let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
			source.setEventHandler { [weak self] in
				var buf = [UInt8](repeating: 0, count: 8192)
				let n = read(master, &buf, buf.count)
				if n > 0 {
					let data = Data(buf[0..<n])
					let b64 = data.base64EncodedString()
					DispatchQueue.main.async {
						self?.webView?.evaluateJavaScript("terminalWrite(atob('\(b64)'))")
					}
				}
			}
			source.resume()
			self.readSource = source
		}

		deinit {
			readSource?.cancel()
			if masterFd >= 0 { close(masterFd) }
		}
	}
}
