import SwiftUI
import WebKit

final class TerminalWebView: WKWebView {
	var onCopyCommand: (() -> Void)?
	var onPasteCommand: (() -> Void)?
	var onLineDeleteCommand: (() -> Void)?
	var onMetaKeyChanged: ((Bool) -> Void)?
	var onMouseFocus: (() -> Void)?

	override var acceptsFirstResponder: Bool { true }

	override func performKeyEquivalent(with event: NSEvent) -> Bool {
		// Only handle Cmd+C/V if this webview (or a child) is the first responder
		guard let firstResponder = window?.firstResponder as? NSView,
			  firstResponder === self || firstResponder.isDescendant(of: self) || isAncestor(of: firstResponder)
		else {
			return super.performKeyEquivalent(with: event)
		}

		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		NSLog(
			"[Belve][keys] performKeyEquivalent chars=%@ ignoring=%@ keyCode=%d flags=%@",
			event.characters ?? "nil",
			event.charactersIgnoringModifiers ?? "nil",
			event.keyCode,
			String(describing: flags)
		)
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
		case String(UnicodeScalar(NSDeleteCharacter)!):
			onLineDeleteCommand?()
			return true
		default:
			if event.keyCode == 51 {
				onLineDeleteCommand?()
				return true
			}
			return super.performKeyEquivalent(with: event)
		}
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

	override func flagsChanged(with event: NSEvent) {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		onMetaKeyChanged?(flags.contains(.command))
		super.flagsChanged(with: event)
	}

	override func mouseDown(with event: NSEvent) {
		onMouseFocus?()
		super.mouseDown(with: event)
	}

	override func rightMouseDown(with event: NSEvent) {
		onMouseFocus?()
		super.rightMouseDown(with: event)
	}

	override func otherMouseDown(with event: NSEvent) {
		onMouseFocus?()
		super.otherMouseDown(with: event)
	}



}

/// SwiftUI wrapper for xterm.js running in WKWebView.
/// Replaces GhosttyTerminalView with a fully embeddable terminal.
struct XTermTerminalView: NSViewRepresentable {
	let project: Project
	var paneId: String?
	var paneIndex: Int = 0
	var viewWidth: CGFloat = 0
	var viewHeight: CGFloat = 0
	@EnvironmentObject var notificationStore: NotificationStore
	@EnvironmentObject var commandAreaState: CommandAreaState

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "terminalHandler")

		let initialFrame = NSRect(x: 0, y: 0, width: max(1, viewWidth), height: max(1, viewHeight))
		let webView = TerminalWebView(frame: initialFrame, configuration: config)
		webView.autoresizingMask = [.width, .height]
		let terminalIdentifier = paneId.map { "BelveTerminalWebView:\($0)" } ?? "BelveTerminalWebView"
		webView.identifier = NSUserInterfaceItemIdentifier(terminalIdentifier)
		webView.setValue(false, forKey: "drawsBackground")
		webView.onCopyCommand = { [weak coordinator = context.coordinator] in
			coordinator?.copySelectionToPasteboard()
		}
		webView.onPasteCommand = { [weak coordinator = context.coordinator] in
			coordinator?.pasteFromPasteboard()
		}
		webView.onLineDeleteCommand = { [weak coordinator = context.coordinator] in
			coordinator?.sendLineDelete()
		}
		webView.onMetaKeyChanged = { [weak coordinator = context.coordinator] isPressed in
			coordinator?.setMetaPressed(isPressed)
		}
		webView.onMouseFocus = { [weak coordinator = context.coordinator] in
			coordinator?.activatePane()
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
		if viewWidth > 0, viewHeight > 0 {
			context.coordinator.triggerFitAddon()
		}
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
		private var isWaitingForInitialOutput = false

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
				guard cols != lastResizeCols || rows != lastResizeRows else { break }
				lastResizeCols = cols
				lastResizeRows = rows
				ptyService?.setSize(cols: cols, rows: rows)

			case "viewportChanged":
				triggerFitAddon()

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
				pasteFromPasteboard()

			case "openPath":
				if let rawPath = body["path"] as? String {
					openPathFromTerminal(rawPath)
				}

			case "shortcut":
				if let key = body["key"] as? String {
					handleShortcut(key: key, shift: body["shift"] as? Bool ?? false)
				}

			case "title":
				// Could update tab/pane title
				break

			case "log":
				if let msg = body["msg"] as? String {
					NSLog("[Belve][xterm] \(msg)")
				}

			default:
				break
			}
		}

		private func startPTY(cols: Int, rows: Int) {
			guard let project else { return }
			isWaitingForInitialOutput = project.isRemote

			// Build environment
			var env: [String: String] = [
				"BELVE_SESSION": "1",
				"BELVE_PROJECT_ID": project.id.uuidString,
				"BELVE_PANE_INDEX": "\(paneIndex)",
				"BELVE_COLS": "\(cols)",
				"BELVE_ROWS": "\(rows)",
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
				postConnectionState(isLoading: isWaitingForInitialOutput)
				postDisconnectedState(isDisconnected: false)
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
				pty.onExit = { [weak self] status in
					self?.handlePTYExit(status: status)
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
				postConnectionState(isLoading: false)
				postDisconnectedState(isDisconnected: project.isRemote)
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
			if isWaitingForInitialOutput, !data.isEmpty {
				isWaitingForInitialOutput = false
				postConnectionState(isLoading: false)
			}
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

		func activatePane() {
			guard let paneId, let paneUUID = UUID(uuidString: paneId) else { return }
			commandAreaState?.activePaneId = paneUUID
		}

		private var resizeDebounceTimer: Timer?
		private var lastResizeCols = 0
		private var lastResizeRows = 0

		/// Debounced resize: fitAddon reads viewport (updated by autoresizingMask) + PTY resize
		func triggerFitAddon() {
			resizeDebounceTimer?.invalidate()
			resizeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
				guard let self else { return }
				self.webView?.evaluateJavaScript("""
					if(window.fitAddon && window.term) {
						window.fitAddon.fit();
						var c = window.term.cols, r = window.term.rows;
						window.webkit.messageHandlers.terminalHandler.postMessage({type:'resize', cols:c, rows:r});
						[c, r];
					}
					""") { [weak self] result, _ in
					guard let self, let arr = result as? [Int], arr.count == 2 else { return }
					self.lastResizeCols = arr[0]
					self.lastResizeRows = arr[1]
				}
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

		func sendLineDelete() {
			ptyService?.send(Data([0x15]))
		}

		func setMetaPressed(_ isPressed: Bool) {
			webView?.evaluateJavaScript("window.terminalSetMetaPressed?.(\(isPressed ? "true" : "false"))", completionHandler: nil)
		}

		private func openPathFromTerminal(_ rawPath: String) {
			guard let project else { return }
			let parts = splitPathAndLocation(rawPath)
			let resolved = resolveTerminalPath(parts.path, in: project)
			guard let resolved else { return }
			NotificationCenter.default.post(
				name: .belveOpenFileFromTerminal,
				object: nil,
				userInfo: [
					"projectId": project.id,
					"path": resolved,
					"line": parts.line as Any,
					"column": parts.column as Any
				]
			)
		}

		private func resolveTerminalPath(_ rawPath: String, in project: Project) -> String? {
			let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'`()[]{}<>"))
			guard !trimmed.isEmpty else { return nil }

			let parts = splitPathAndLocation(trimmed)
			let candidate = parts.path
			let ctx = project.executionContext
			let basePath = project.effectivePath

			let candidates: [String]
			if candidate.hasPrefix("/") {
				candidates = [candidate]
			} else if candidate.hasPrefix("./") || candidate.hasPrefix("../") {
				candidates = [
					(basePath as NSString).appendingPathComponent(candidate)
				]
			} else {
				candidates = [
					(basePath as NSString).appendingPathComponent(candidate),
					candidate
				]
			}

			for path in candidates {
				if ctx.fileExists(path) {
					return path
				}
			}
			return nil
		}

		private func splitPathAndLocation(_ rawPath: String) -> (path: String, line: Int?, column: Int?) {
			let parts = rawPath.split(separator: ":").map(String.init)
			guard parts.count >= 2 else { return (rawPath, nil, nil) }

			if parts.count >= 3,
			   let line = Int(parts[parts.count - 2]),
			   let column = Int(parts[parts.count - 1]) {
				let path = parts.dropLast(2).joined(separator: ":")
				return (path, line, column)
			}

			if let last = parts.last, let line = Int(last) {
				let path = parts.dropLast().joined(separator: ":")
				return (path, line, nil)
			}

			return (rawPath, nil, nil)
		}

		private func postConnectionState(isLoading: Bool) {
			guard let project, let paneId else { return }
			NotificationCenter.default.post(
				name: .belveTerminalConnectionState,
				object: nil,
				userInfo: [
					"projectId": project.id,
					"paneId": paneId,
					"isLoading": isLoading
				]
			)
		}

		private func postDisconnectedState(isDisconnected: Bool) {
			guard let project, let paneId else { return }
			NotificationCenter.default.post(
				name: .belveTerminalDisconnected,
				object: nil,
				userInfo: [
					"projectId": project.id,
					"paneId": paneId,
					"isDisconnected": isDisconnected
				]
			)
		}

		private func handlePTYExit(status: Int32) {
			postConnectionState(isLoading: false)
			guard let project else { return }
			// Skip if our webView is no longer in the view hierarchy (stale coordinator from reload)
			guard webView?.window != nil else { return }
			if project.isRemote {
				postDisconnectedState(isDisconnected: true)
			}
			NSLog(
				"[Belve] PTY exited for project=%@ pane=%@ status=%d",
				project.name,
				paneId ?? "nil",
				status
			)
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
			case "]":
				NotificationCenter.default.post(name: .belveSelectNextProject, object: nil)
			case "[":
				NotificationCenter.default.post(name: .belveSelectPreviousProject, object: nil)
			case "'":
				NotificationCenter.default.post(name: .belveFocusNextPane, object: nil)
			case ";":
				NotificationCenter.default.post(name: .belveFocusPreviousPane, object: nil)
			case "l":
				NotificationCenter.default.post(name: .belveFocusEditor, object: nil)
			case "\\":
				NotificationCenter.default.post(name: .belveToggleSidebar, object: nil)
			case "e":
				if shift {
					NotificationCenter.default.post(name: .belveToggleFileTree, object: nil)
				} else {
					NotificationCenter.default.post(name: .belveToggleEditor, object: nil)
				}
			case "z":
				if !shift {
					NotificationCenter.default.post(name: .belveUndo, object: nil)
				}
			case "t":
				if shift {
					// Debug: report dimensions then resize to 40x20
					webView?.evaluateJavaScript("JSON.stringify(window.debugDimensions())") { result, _ in
						NSLog("[Belve] DEBUG dims pane=%@ %@", self.paneId ?? "nil", result as? String ?? "nil")
					}
					NSLog("[Belve] DEBUG: triggering debugResize(40, 20) on pane=%@", paneId ?? "nil")
					webView?.evaluateJavaScript("window.debugResize(40, 20)", completionHandler: nil)
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
			postConnectionState(isLoading: false)
			postDisconnectedState(isDisconnected: false)
			ptyService = nil  // PTYService deinit closes fd and kills process
			NSLog("[Belve] Terminal coordinator deinit")
		}
	}
}
