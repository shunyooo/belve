import SwiftUI
import WebKit

final class TerminalWebView: WKWebView {
	var onCopyCommand: (() -> Void)?
	var onPasteCommand: (() -> Void)?

	override var acceptsFirstResponder: Bool { true }

	override func performKeyEquivalent(with event: NSEvent) -> Bool {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		guard flags == [.command],
			  let key = event.charactersIgnoringModifiers?.lowercased() else {
			return super.performKeyEquivalent(with: event)
		}

		switch key {
		case "c":
			onCopyCommand?()
			return true
		case "v":
			onPasteCommand?()
			return true
		default:
			return super.performKeyEquivalent(with: event)
		}
	}

}

/// SwiftUI wrapper for xterm.js running in WKWebView.
/// Replaces GhosttyTerminalView with a fully embeddable terminal.
struct XTermTerminalView: NSViewRepresentable {
	let project: Project
	var paneId: String?
	var paneIndex: Int = 0
	@EnvironmentObject var notificationStore: NotificationStore
	@EnvironmentObject var commandAreaState: CommandAreaState

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "terminalHandler")

		let webView = TerminalWebView(frame: .zero, configuration: config)
		webView.setValue(false, forKey: "drawsBackground")
		webView.onCopyCommand = { [weak coordinator = context.coordinator] in
			coordinator?.copySelectionToPasteboard()
		}
		webView.onPasteCommand = { [weak coordinator = context.coordinator] in
			coordinator?.pasteFromPasteboard()
		}
		context.coordinator.webView = webView
		context.coordinator.project = project
		context.coordinator.paneId = paneId
		context.coordinator.paneIndex = paneIndex
		context.coordinator.notificationStore = notificationStore
		context.coordinator.commandAreaState = commandAreaState

		if let html = Self.buildHTML() {
			webView.loadHTMLString(html, baseURL: nil)
		}

		// Register pane → project mapping for agent notifications
		if let paneId {
			notificationStore.registerPane(paneId: paneId, projectId: project.id)
		}

		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
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

		guard let htmlTemplate = try? String(contentsOf: resourceDir.appendingPathComponent("terminal.html")),
			  let js = try? String(contentsOf: resourceDir.appendingPathComponent("terminal-bundle.js")),
			  let css = try? String(contentsOf: resourceDir.appendingPathComponent("xterm.css"))
		else {
			NSLog("[Belve] Failed to load terminal resources from \(bundlePath.path) or \(fallbackPath.path)")
			return nil
		}

		return htmlTemplate
			.replacingOccurrences(of: "/* XTERM_CSS */", with: css)
			.replacingOccurrences(of: "/* TERMINAL_JS */", with: js)
	}

	// MARK: - Coordinator

	class Coordinator: NSObject, WKScriptMessageHandler {
		weak var webView: WKWebView?
		var project: Project?
		var paneId: String?
		var paneIndex: Int = 0
		var ptyService: PTYService?
		weak var notificationStore: NotificationStore?
		weak var commandAreaState: CommandAreaState?

		/// Buffer PTY output and flush on a timer to avoid excessive JS calls
		private var outputBuffer = Data()
		private var flushTimer: Timer?

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
				  let type = body["type"] as? String else { return }

			switch type {
			case "ready":
				let cols = body["cols"] as? Int ?? 80
				let rows = body["rows"] as? Int ?? 24
				startPTY(cols: cols, rows: rows)
				focusTerminal()

			case "input":
				if let b64 = body["data"] as? String,
				   let data = Data(base64Encoded: b64) {
					ptyService?.send(data)
				}

			case "resize":
				let cols = body["cols"] as? Int ?? 80
				let rows = body["rows"] as? Int ?? 24
				ptyService?.setSize(cols: cols, rows: rows)

			case "bell":
				NSSound.beep()

			case "copy":
				if let text = body["text"] as? String {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
				}

			case "selection":
				// Store selection for Cmd+C
				if let text = body["text"] as? String {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
				}

			case "paste":
				if let text = NSPasteboard.general.string(forType: .string) {
					ptyService?.send(text)
				}

			case "shortcut":
				if let key = body["key"] as? String {
					handleShortcut(key: key, shift: body["shift"] as? Bool ?? false)
				}

			case "title":
				// Could update tab/pane title
				break

			default:
				break
			}
		}

		private func startPTY(cols: Int, rows: Int) {
			guard let project else { return }

			// Build environment
			var env: [String: String] = [
				"BELVE_SESSION": "1",
				"BELVE_PROJECT_ID": project.id.uuidString,
				"BELVE_PANE_INDEX": "\(paneIndex)",
			]
			if let paneId {
				env["BELVE_PANE_ID"] = paneId
			}

			// Add Belve's bin directory to PATH
			if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
				let resourceBin = execDir
					.deletingLastPathComponent()
					.appendingPathComponent("Resources/bin")
				let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
				env["PATH"] = "\(resourceBin.path):\(currentPath)"
			}

			// SSH/DevContainer env vars (used by launcher script)
			if project.isDevContainer, let sshHost = project.sshHost, let workspacePath = project.devContainerPath {
				env["BELVE_SSH_HOST"] = sshHost
				env["BELVE_REMOTE_PATH"] = workspacePath
				env["BELVE_DEVCONTAINER"] = "1"
			} else if let sshHost = project.sshHost {
				env["BELVE_SSH_HOST"] = sshHost
				if let remotePath = project.remotePath {
					env["BELVE_REMOTE_PATH"] = remotePath
				}
			}

			// Resolve launcher script path
			let launcherPath = "/tmp/belve-shell/belve-launcher.sh"

			do {
				let pty = try PTYService.spawn(
					shell: launcherPath,
					args: [],
					environment: env,
					cols: cols,
					rows: rows
				)

				pty.onData = { [weak self] data in
					self?.bufferOutput(data)
				}

				// Agent notification transport
				if paneId != nil {
					pty.agentTransport.onAgentStatus = { [weak self] agentPaneId, status, message in
						self?.notificationStore?.updateAgentStatus(
							paneId: agentPaneId, status: status, message: message
						)
					}
				}

				self.ptyService = pty
				NSLog("[Belve] PTY started for project: \(project.name), pane: \(paneId ?? "nil")")
			} catch {
				NSLog("[Belve] Failed to start PTY: \(error)")
			}

			// Track active pane on focus
			if let paneId, let paneUUID = UUID(uuidString: paneId) {
				// Set active pane when this terminal gets focus
				DispatchQueue.main.async { [weak self] in
					self?.commandAreaState?.activePaneId = paneUUID
				}
			}
		}

		/// Buffer PTY output and flush every ~4ms to reduce JS calls
		private func bufferOutput(_ data: Data) {
			outputBuffer.append(data)
			if flushTimer == nil {
				flushTimer = Timer.scheduledTimer(withTimeInterval: 0.004, repeats: false) { [weak self] _ in
					self?.flushOutput()
				}
			}
		}

		private func flushOutput() {
			flushTimer = nil
			guard !outputBuffer.isEmpty else { return }
			let b64 = outputBuffer.base64EncodedString()
			outputBuffer.removeAll(keepingCapacity: true)
			webView?.evaluateJavaScript("terminalWrite('\(b64)')", completionHandler: nil)
		}

		private func focusTerminal() {
			DispatchQueue.main.async { [weak self] in
				self?.webView?.window?.makeFirstResponder(self?.webView)
				self?.webView?.evaluateJavaScript("terminalFocus(true)", completionHandler: nil)
			}
		}

		func copySelectionToPasteboard() {
			webView?.evaluateJavaScript("window.terminalGetSelection ? window.terminalGetSelection() : ''") { result, _ in
				guard let text = result as? String, !text.isEmpty else { return }
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(text, forType: .string)
			}
		}

		func pasteFromPasteboard() {
			guard let text = NSPasteboard.general.string(forType: .string) else { return }
			ptyService?.send(text)
		}

		private func handleShortcut(key: String, shift: Bool) {
			switch key {
			case "d":
				if shift {
					commandAreaState?.splitActive(.horizontal)
				} else {
					commandAreaState?.splitActive(.vertical)
				}
			case "w":
				commandAreaState?.closeActivePane()
			case "n":
				NotificationCenter.default.post(name: .belveNewProject, object: nil)
			case "p":
				if shift {
					NotificationCenter.default.post(name: .belveCommandPalette, object: nil)
				}
			case "o":
				NotificationCenter.default.post(name: .belveOpenFolder, object: nil)
			case "s":
				NotificationCenter.default.post(name: .belveFileSave, object: nil)
			case "r":
				NotificationCenter.default.post(name: .belveReloadProject, object: nil)
			case "z":
				if !shift {
					NotificationCenter.default.post(name: .belveUndo, object: nil)
				}
			default:
				// Forward Cmd+1-9 for project switching
				if let digit = Int(key), digit >= 1 && digit <= 9 {
					NotificationCenter.default.post(name: .belveSwitchProject, object: nil, userInfo: ["index": digit - 1])
				}
			}
		}

		deinit {
			flushTimer?.invalidate()
			ptyService = nil  // PTYService deinit closes fd and kills process
			NSLog("[Belve] Terminal coordinator deinit")
		}
	}
}
